from .impls import *
from emberserde.error import DeserializationError, DerErrorKind


trait Deserializable(Movable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        ...


trait SeqDerState(ImplicitlyDestructible):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait MapDerState(ImplicitlyDestructible):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait StructDerState(ImplicitlyDestructible):
    def expect_field_name(mut self) raises DeserializationError -> String:
        ...

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait Deserializer:
    comptime SeqType: SeqDerState
    comptime MapType: MapDerState
    comptime StructType: StructDerState

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

    def begin_struct(mut self) raises DeserializationError -> Self.StructType:
        ...

    # TODO: Have an `expect_seq` like we do in `Serializer`.
    # We don't currently have a generic approach for adding an item into
    # a collection so we can't do it yet.


    def expect_struct[
        T: ImplicitlyDestructible
    ](mut self, out result: T) raises DeserializationError:
        ...


def deserialize[
    T: AnyType
](mut d: Some[Deserializer]) raises DeserializationError -> T:
    comptime if conforms_to(T, Deserializable):
        return T.deserialize(d)
    elif conforms_to(T, ImplicitlyDestructible):
        return d.expect_struct[T]()
    else:
        comptime assert False, "Cannot deserialize linear type"
