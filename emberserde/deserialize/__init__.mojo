from std.builtin.rebind import downcast
from std.reflection import reflect

from .impls import *
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field_meta import FieldMeta, name_matches
from emberserde.struct_modifiers import RenameAll, DenyUnknownFields
from emberserde.utils import Base


def _all_dtors_are_trivial[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime type = r.field_types()[i]
        if not downcast[type, ImplicitlyDeletable].__del__is_trivial:
            return False
    return True


# `Optional` fields are the one shape allowed to be absent on the wire: a
# missing optional field deserializes to its empty default instead of raising
# `MissingField`.
def __is_optional[T: AnyType]() -> Bool:
    return reflect[T].base_name() == "Optional"


# May field `i` be absent from the wire? `Optional` always; a `Field` when it is
# skipped or carries a default. Everything else is required.
def _fill_if_missing[FT: AnyType]() -> Bool:
    comptime if __is_optional[FT]():
        return True
    elif conforms_to(FT, FieldMeta):
        return downcast[FT, FieldMeta].serde_fill_if_missing
    else:
        return False


trait Deserializable(Movable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        ...


trait SeqDerState(ImplicitlyDeletable):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait TupleDerState(ImplicitlyDeletable):
    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait MapDerState(ImplicitlyDeletable):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait StructDerState(ImplicitlyDeletable):
    # Returns `None` when the struct has no more fields (without consuming
    # the closing delimiter — that is `end`'s job). Self-describing formats
    # read the name off the wire; non-self-describing formats return the
    # next field name from `reflect[T]` in declaration order.
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


trait Deserializer:
    comptime SeqType: SeqDerState
    comptime MapType: MapDerState
    comptime StructType: StructDerState
    comptime TupleType: TupleDerState

    def expect_bool(mut self) raises DeserializationError -> Bool:
        ...

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        ...

    def expect_string(mut self) raises DeserializationError -> String:
        ...

    def expect_optional[
        T: Movable
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

    # TODO: Have an `expect_seq` like we do in `Serializer`.
    # We don't currently have a generic approach for adding an item into
    # a collection so we can't do it yet.

    def expect_struct[
        T: ImplicitlyDeletable
    ](mut self, out result: T) raises DeserializationError:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "expect_struct requires a struct type"
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
        var seen = InlineArray[Bool, r.field_count()](fill=False)

        while True:
            var name_opt = st.expect_field_name()
            if not name_opt:
                break
            var name = name_opt.value()

            var matched = False
            comptime for i in range(r.field_count()):
                if not matched and name_matches[T, r.field_types()[i]](
                    names[i], name
                ):
                    if seen[i]:
                        raise DeserializationError(
                            String(t"duplicate field: {names[i]}"),
                            DerErrorKind.DuplicateField,
                        )
                    seen[i] = True
                    matched = True
                    comptime FT = downcast[r.field_types()[i], Base]
                    trait_downcast[Base](
                        r.field_ref[i](result)
                    ) = st.expect_field_value[FT]()
            if not matched:
                comptime if conforms_to(T, DenyUnknownFields):
                    raise DeserializationError(
                        String(t"Unknown field: {name}"),
                        DerErrorKind.UnknownField,
                    )
                else:
                    st.skip_value()

        comptime for i in range(r.field_count()):
            if not seen[i]:
                comptime if _fill_if_missing[r.field_types()[i]]():
                    ref f = trait_downcast[Base & Defaultable](
                        r.field_ref[i](result)
                    )
                    f = type_of(f)()
                else:
                    raise DeserializationError(
                        String(t"missing field: {names[i]}"),
                        DerErrorKind.MissingField,
                    )

        st.end()


def deserialize[
    T: AnyType
](mut d: Some[Deserializer]) raises DeserializationError -> T:
    comptime if conforms_to(T, Deserializable):
        return T.deserialize(d)
    elif conforms_to(T, ImplicitlyDeletable):
        return d.expect_struct[T]()
    else:
        comptime assert False, "Cannot deserialize linear type"
