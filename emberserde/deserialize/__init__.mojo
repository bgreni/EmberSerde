from std.builtin.rebind import downcast
from std.reflection import reflect

from .impls import *
from .borrow import BorrowingDeserializer, RawKind
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field_meta import (
    FieldMeta,
    __is_optional,
    has_unique_wire_names,
    is_skipped,
)
from emberserde.struct_modifiers import RenameAll, DenyUnknownFields
from emberserde.utils import Base, unimplemented


# The fields `expect_struct` has bound so far: one bit per field, packed in
# 64-bit words, so a struct of up to 64 fields tracks them in one register.
struct _FieldSet[n: Int](Copyable, Movable):
    comptime _WORDS = max(1, (Self.n + 63) // 64)
    var _bits: Array[UInt64, Self._WORDS]

    @always_inline
    def __init__(out self):
        self._bits = Array[UInt64, Self._WORDS](fill=0)

    @always_inline
    def contains[i: Int](self) -> Bool:
        return (self._bits[i // 64] >> UInt64(i % 64)) & 1 != 0

    @always_inline
    def add[i: Int](mut self):
        self._bits[i // 64] |= UInt64(1) << UInt64(i % 64)


# Error construction for `expect_struct`, kept out of line: each is reached
# only on failure, but `expect_struct` instantiates a site per field, and the
# inline string formatting at every one of them bloats the hot field loop.
@no_inline
def _duplicate_field(name: StaticString) -> DeserializationError:
    return DeserializationError(
        String(t"duplicate field: {name}"), DerErrorKind.DuplicateField
    )


@no_inline
def _missing_field(name: StaticString) -> DeserializationError:
    return DeserializationError(
        String(t"missing field: {name}"), DerErrorKind.MissingField
    )


@no_inline
def _prepend_field(mut e: DeserializationError, name: StaticString):
    e.prepend_path(String(t".{name}"))


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
    # The declaration index (position in `reflect[T]`'s fields) of the next
    # field on the wire, or `None` when the struct has no more fields (without
    # consuming the closing delimiter — that is `end`'s job). An index rather
    # than a name — mirroring `EnumDerState.variant_index` — so a keyed format
    # can resolve the key as a borrowed slice and an ordered format never has
    # to invent names just to have them matched back. Self-describing formats
    # read the key off the wire and resolve it with `field_index[T]`
    # (`UNKNOWN_FIELD` when nothing binds); non-self-describing formats step
    # through `next_wire_field[T]`.
    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
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

    def expect_bool(mut self) raises DeserializationError -> Bool:
        ...

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        ...

    def expect_string(mut self) raises DeserializationError -> String:
        ...

    # The read side of `serialize_bytes`. Defaulted the same way, so a format
    # with no byte encoding fails at comptime only when a type asks for one.
    def expect_bytes(mut self) raises DeserializationError -> List[Byte]:
        unimplemented["expect_bytes"]()
        return []

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

    # FRAMEWORK DRIVER, not a format hook: the default body runs
    # `deserialize_struct`, the framework's field-evolution logic (name
    # matching, rename/alias/skip, duplicate/unknown/missing handling, error
    # paths). A format that overrides it must still hand every struct it does
    # not settle itself to `deserialize_struct`, or it silently opts out of
    # all of that -- implement `begin_struct`/`StructDerState` instead.
    def expect_struct[
        T: Deinitable
    ](mut self, out result: T) raises DeserializationError:
        result = deserialize_struct[T](self)


def deserialize_struct[
    T: Deinitable
](mut d: Some[Deserializer], out result: T) raises DeserializationError:
    """The framework's struct driver: reads `T` field by field through `d`'s
    `begin_struct`/`StructDerState`, applying renames, aliases and skips,
    rejecting duplicates and (under `DenyUnknownFields`) unknown fields, and
    filling or rejecting missing ones.

    `Deserializer.expect_struct` runs it by default. A format may override
    `expect_struct` to settle common shapes faster, as long as everything it
    does not settle itself ends up here.
    """
    comptime r = reflect[T]
    comptime assert r.is_struct(), "expect_struct requires a struct type"
    comptime assert has_unique_wire_names[
        T
    ](), "two fields resolve to the same wire name (check renames and rename_all)"
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

    var st = d.begin_struct[T]()
    var seen = _FieldSet[r.field_count()]()
    # One handler for the whole field loop rather than one per field:
    # `current` is the field whose value is being read (-1 between
    # values), so only a failure inside a value gets its name prepended.
    var current = -1
    try:
        while True:
            var field = st.expect_field_index[T]()
            if not field:
                break
            var idx = field.value()

            var matched = False
            comptime for i in range(r.field_count()):
                # A skipped field never binds, whatever index the format
                # hands back.
                comptime if not is_skipped[r.field_types()[i]]():
                    # Index at comptime so only the one name
                    # materializes, not the whole (non-ImplicitlyCopyable)
                    # field-names array.
                    comptime declared_name = names[i]
                    if idx == i:
                        if seen.contains[i]():
                            raise _duplicate_field(declared_name)
                        seen.add[i]()
                        matched = True
                        comptime assert conforms_to(
                            r.field_types()[i], Base
                        ), "field types must be Movable & Deinitable"
                        comptime FT = downcast[r.field_types()[i], Base]
                        current = i
                        r.field_ref[i](result) = st.expect_field_value[FT]()
                        current = -1
            if not matched:
                # `field_index` already raised with the key's name; this
                # nameless raise only catches a format that resolved the
                # key itself.
                comptime if conforms_to(T, DenyUnknownFields):
                    raise DeserializationError(
                        String("Unknown field"),
                        DerErrorKind.UnknownField,
                    )
                else:
                    st.skip_value()
    except e:
        comptime for i in range(r.field_count()):
            comptime declared_name = names[i]
            if current == i:
                _prepend_field(e, declared_name)
        raise e^

    comptime for i in range(r.field_count()):
        comptime declared_name = names[i]
        if not seen.contains[i]():
            comptime if _fill_if_missing[r.field_types()[i]]():
                comptime if conforms_to(r.field_types()[i], FieldMeta):
                    # `Field` fills through its own hook so an explicit
                    # `default` works without `T` being Defaultable.
                    comptime FMT = downcast[r.field_types()[i], FieldMeta]
                    r.field_ref[i](result) = FMT.serde_filled()
                else:
                    comptime assert conforms_to(
                        r.field_types()[i], Base & Defaultable
                    ), "Missing field must be Defaulable & Movable & Deinitable"
                    ref f = r.field_ref[i](result)
                    f = type_of(f)()
            else:
                raise _missing_field(declared_name)

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
