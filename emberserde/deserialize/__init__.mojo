from std.builtin.rebind import downcast
from std.reflection import reflect

from .impls import *
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field_meta import (
    FieldMeta,
    __is_optional,
    has_unique_wire_names,
    name_matches,
)
from emberserde.struct_modifiers import RenameAll, DenyUnknownFields
from emberserde.utils import Base


def _all_dtors_are_trivial[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime type = r.field_types()[i]
        if not downcast[type, Deinitable].__del__is_trivial:
            return False
    return True


# May field `i` be absent from the wire? `Optional` always; a `Field` when it is
# skipped or carries a default. Everything else is required.
def _fill_if_missing[FT: AnyType]() -> Bool:
    comptime if __is_optional[FT]():
        return True
    elif conforms_to(FT, FieldMeta):
        return downcast[FT, FieldMeta].serde_fill_if_missing
    else:
        return False


# Parse a numeric token into `Scalar[DT]`, raising instead of silently
# wrapping: `checked_scalar[DType.uint8]("300")` is an error, not 44. Text
# formats should parse numbers through this rather than `Scalar[DT](atol(...))`,
# which truncates/sign-wraps anything out of range.
def checked_scalar[
    DT: DType
](tok: String) raises DeserializationError -> Scalar[DT]:
    comptime if DT.is_floating_point():
        try:
            return atof(tok).cast[DT]()
        except:
            raise DeserializationError(
                String(t"invalid number: '{tok}'"),
                DerErrorKind.InvalidValue,
            )
    else:
        var i: Int
        try:
            i = atol(tok)
        except:
            raise DeserializationError(
                String(t"invalid number: '{tok}'"),
                DerErrorKind.InvalidValue,
            )
        comptime if DT.is_unsigned():
            if i < 0:
                raise DeserializationError(
                    String(t"number out of range for {DT}: '{tok}'"),
                    DerErrorKind.InvalidValue,
                )
        var result = Scalar[DT](i)
        # A 64-bit `Int` survives the round trip through DT iff it fits;
        # a mismatch means truncation (negatives were rejected above, so
        # unsigned wrap-back can't fool the comparison).
        if Int(result) != i:
            raise DeserializationError(
                String(t"number out of range for {DT}: '{tok}'"),
                DerErrorKind.InvalidValue,
            )
        return result


trait Deserializable(Movable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        ...


trait SeqDerState(Deinitable):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait TupleDerState(Deinitable):
    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait MapDerState(Deinitable):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait StructDerState(Deinitable):
    # Returns `None` when the struct has no more fields (without consuming
    # the closing delimiter — that is `end`'s job). Self-describing formats
    # read the name off the wire; non-self-describing formats serve
    # `wire_field_names[T]()` (wire names of non-skipped fields, declaration
    # order — NOT declared names, which diverge under `Rename`/`RenameAll`/
    # `Skip` and would fall through to `skip_value`).
    def expect_field_name(
        mut self,
    ) raises DeserializationError -> Optional[String]:
        ...

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        ...

    # Consume one value without binding it — used to ignore unknown fields.
    def skip_value(mut self) raises DeserializationError:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait EnumDerState(Deinitable):
    # The resolved arm index (position in the variant's arm list). `begin_enum`
    # has already consumed the wire tag and mapped it to an index — self-
    # describing formats look the arm name up in the supplied arm names; binary
    # formats read a discriminant index directly. A value outside the arm range
    # signals an unknown variant, which the `Variant` impl turns into an error.
    def variant_index(mut self) raises DeserializationError -> Int:
        ...

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait Deserializer:
    comptime SeqType: SeqDerState
    comptime MapType: MapDerState
    comptime StructType: StructDerState
    comptime TupleType: TupleDerState
    comptime EnumType: EnumDerState

    # Lazy error-path tracking: descent sites (struct fields, seq/map/tuple
    # elements) wrap their reads in try/except and prepend a path segment
    # (`.name`, `[i]`) to `DeserializationError.path` on the way out. Costs
    # nothing on the happy path; a format can opt out entirely by declaring
    # this False, which comptime-removes the wraps.
    comptime track_error_paths: Bool = True

    def expect_bool(mut self) raises DeserializationError -> Bool:
        ...

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        ...

    def expect_string(mut self) raises DeserializationError -> String:
        ...

    # `Base` (not just `Movable`): a format whose optional encoding has
    # trailing framing after the payload must be able to drop the payload
    # when reading that framing fails.
    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        ...

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        ...

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        ...

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        ...

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        ...

    # Externally-tagged sum type. `arm_names` are the variant's arm type names
    # in declaration order (the impl supplies them since `reflect` cannot
    # enumerate variant arms); the format maps the wire tag to a position in
    # this list, surfaced via `EnumDerState.variant_index`. A comptime
    # parameter — mirroring the serialize side — so name-tagged formats can
    # intern the candidates instead of heap-building a list per value.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        ...

    # TODO: Have an `expect_seq` like we do in `Serializer`.
    # We don't currently have a generic approach for adding an item into
    # a collection so we can't do it yet.

    # FRAMEWORK DRIVER, not a format hook: this default body is the
    # framework's field-evolution logic (name matching, rename/alias/skip,
    # duplicate/unknown/missing handling, error paths) riding on the trait
    # for dispatch. A format that overrides it silently opts out of all of
    # that — implement `begin_struct`/`StructDerState` instead.
    def expect_struct[
        T: Deinitable
    ](mut self, out result: T) raises DeserializationError:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "expect_struct requires a struct type"
        comptime assert has_unique_wire_names[T](), (
            "two fields resolve to the same wire name (check renames and"
            " rename_all)"
        )
        comptime names = r.field_names()

        comptime if conforms_to(T, Defaultable):
            result = T()
        else:
            comptime assert _all_dtors_are_trivial[T](), (
                "Cannot deserialize non-Defaultable struct containing fields"
                " with non-trivial destructors"
            )
            __mlir_op.`lit.ownership.mark_initialized`(
                __get_mvalue_as_litref(result)
            )

        var st = self.begin_struct[T]()
        var seen = Array[Bool, r.field_count()](fill=False)

        while True:
            var name_opt = st.expect_field_name()
            if not name_opt:
                break
            var name = name_opt.value()

            var matched = False
            comptime for i in range(r.field_count()):
                # Index at comptime so only the one name materializes, not the
                # whole (non-ImplicitlyCopyable) field-names array.
                comptime declared_name = names[i]
                if not matched and name_matches[
                    T, r.field_types()[i], declared_name
                ](name):
                    if seen[i]:
                        raise DeserializationError(
                            String(t"duplicate field: {declared_name}"),
                            DerErrorKind.DuplicateField,
                        )
                    seen[i] = True
                    matched = True
                    comptime assert conforms_to(
                        r.field_types()[i], Base
                    ), "field types must be Movable & Deinitable"
                    comptime FT = downcast[r.field_types()[i], Base]
                    comptime if Self.track_error_paths:
                        try:
                            r.field_ref[i](result) = st.expect_field_value[FT]()
                        except e:
                            e.prepend_path(String(t".{declared_name}"))
                            raise e^
                    else:
                        r.field_ref[i](result) = st.expect_field_value[FT]()
            if not matched:
                comptime if conforms_to(T, DenyUnknownFields):
                    raise DeserializationError(
                        String(t"Unknown field: {name}"),
                        DerErrorKind.UnknownField,
                    )
                else:
                    st.skip_value()

        comptime for i in range(r.field_count()):
            comptime declared_name = names[i]
            if not seen[i]:
                comptime if _fill_if_missing[r.field_types()[i]]():
                    comptime if conforms_to(r.field_types()[i], FieldMeta):
                        # `Field` fills through its own hook so an explicit
                        # `default` works without `T` being Defaultable.
                        comptime FMT = downcast[r.field_types()[i], FieldMeta]
                        r.field_ref[i](result) = FMT.serde_filled()
                    else:
                        comptime assert conforms_to(
                            r.field_types()[i], Base & Defaultable
                        ), (
                            "Missing field must be Defaulable & Movable &"
                            " Deinitable"
                        )
                        ref f = r.field_ref[i](result)
                        f = type_of(f)()
                else:
                    raise DeserializationError(
                        String(t"missing field: {declared_name}"),
                        DerErrorKind.MissingField,
                    )

        st.end()


def deserialize[
    T: AnyType
](mut d: Some[Deserializer]) raises DeserializationError -> T:
    comptime if conforms_to(T, Deserializable):
        return T.deserialize(d)
    elif conforms_to(T, Deinitable):
        return d.expect_struct[T]()
    else:
        comptime assert False, "Cannot deserialize linear type"


trait SelfDescribingDeserializer(Deserializer):
    comptime Value: Deserializable

    def deserialize_any(mut self) raises DeserializationError -> Self.Value:
        ...
