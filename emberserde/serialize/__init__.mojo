import emberserde
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


# TODO: Perhaps the size of the tuple could be a parameter in the future.
trait TupleSerState(ImplicitlyDestructible):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait Serializer:
    comptime MapType: MapSerState
    comptime SeqType: SeqSerState
    comptime StructType: StructSerState
    comptime TupleType: TupleSerState

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

    # A present `Optional` routes through here so the format gets a hook to
    # emit a presence marker before the payload. Self-describing formats
    # (JSON-like) can keep this transparent default; non-self-describing
    # formats (bincode-like) MUST override it to tag the payload, otherwise
    # `Some(v)` and a bare `v` are byte-identical on the wire and
    # `expect_optional` cannot decode unambiguously.
    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        emberserde.serialize.serialize(v, self)

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        unimplemented()

    # `size_hint` is the element count when the caller knows it up front.
    # Self-describing formats may ignore it; binary formats that must write a
    # length prefix should raise if it is absent.
    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        ...

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        ...

    def begin_struct[
        name: String
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        ...

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        ...

    def serialize_seq[
        Seq: Iterable & ImplicitlyDestructible
    ](mut self, v: Seq) raises SerializationError:
        # TODO: Switch to nice for loop syntax when it works

        # var st = self.begin_seq(size_hint)
        # for ref element in v:
        #     st.serialize_element(element)

        # st.end()

        var size_hint: Optional[Int]
        comptime if conforms_to(Seq, Sized):
            size_hint = len(trait_downcast[Sized](v))
        else:
            size_hint = None

        var st = self.begin_seq(size_hint)
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

        var state = self.begin_struct[r.name()](field_count)

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
