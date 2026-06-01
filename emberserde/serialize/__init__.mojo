from emberserde.utils import unimplemented
from std.reflection import (
    reflect,
)

from .impls import *
from emberserde.error import SerializationError


trait Serializable:
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        ...


trait SeqSerState(ImplicitlyDestructible):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait MapSerState(ImplicitlyDestructible):
    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        ...

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait StructSerState(ImplicitlyDestructible):
    def serialize_field(
        mut self, field_name: String, v: Some[AnyType]
    ) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


# With parametric traits we could make this generic over some Writer
trait Serializer:
    comptime MapType: MapSerState
    comptime SeqType: SeqSerState
    comptime StructType: StructSerState

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        unimplemented()

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        unimplemented()

    def serialize_string(mut self, v: String) raises SerializationError:
        unimplemented()

    def serialize_none(mut self) raises SerializationError:
        unimplemented()

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        unimplemented()

    def begin_seq(mut self) -> Self.SeqType:
        ...

    def begin_map(mut self) -> Self.MapType:
        ...

    def begin_struct[name: String](mut self) -> Self.StructType:
        ...

    def serialize_seq[
        Seq: Iterable & ImplicitlyDestructible
    ](mut self, v: Seq) raises SerializationError:
        # TODO: Switch to nice for loop syntax when it works

        # var st = self.begin_seq()
        # for ref element in v:
        #     st.serialize_element(element)

        # st.end()

        var st = self.begin_seq()
        var it = v.__iter__()
        while True:
            var element: type_of(it).Element
            try:
                element = it.__next__()
            except e:
                break
            st.serialize_element(
                trait_downcast_var[ImplicitlyDestructible & Movable](element^)
            )
        st.end()

    def serialize_struct[T: AnyType](mut self, v: T) raises SerializationError:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "Cannot serialize MLIR type"

        comptime field_count = r.field_count()
        comptime field_names = r.field_names()

        var state = self.begin_struct[r.name()]()

        comptime for i in range(field_count):
            state.serialize_field(field_names[i], r.field_ref[i](v))

        state.end()


def serialize[
    T: AnyType, //
](value: T, mut s: Some[Serializer]) raises SerializationError:
    comptime if conforms_to(T, Serializable):
        value.serialize(s)
    else:
        s.serialize_struct(value)
