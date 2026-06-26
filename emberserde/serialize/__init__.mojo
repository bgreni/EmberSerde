import emberserde
from emberserde.utils import unimplemented, Base
from std.reflection import (
    reflect,
)

from .impls import *
from emberserde.error import SerializationError
from emberserde.field_meta import wire_name, visible_fields, is_skipped


trait Serializable:
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        ...


trait SeqSerState(ImplicitlyDeletable):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait MapSerState(ImplicitlyDeletable):
    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        ...

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait StructSerState(ImplicitlyDeletable):
    def serialize_field(
        mut self, field_name: String, v: Some[AnyType]
    ) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


# TODO: Perhaps the size of the tuple could be a parameter in the future.
trait TupleSerState(ImplicitlyDeletable):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait EnumSerState(ImplicitlyDeletable):
    # Called exactly once with the active arm's value. The payload's shape
    # (primitive/struct/tuple) falls out of normal serialization — no per-shape
    # methods are needed on the format.
    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait Serializer:
    comptime MapType: MapSerState
    comptime SeqType: SeqSerState
    comptime StructType: StructSerState
    comptime TupleType: TupleSerState
    comptime EnumType: EnumSerState

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

    # Externally-tagged sum type. `name` is the enum type's name; `variant` is
    # the active arm's type name (the tag); `idx` is the arm's position (the
    # discriminant a binary format would write). Self-describing formats key on
    # `variant`; non-self-describing formats key on `idx`.
    def begin_enum[
        name: String, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        ...

    def serialize_seq[
        Seq: Iterable
    ](mut self, v: Seq) raises SerializationError:
        # TODO: Switch to nice for loop syntax when it works

        # var st = self.begin_seq(size_hint)
        # for ref element in v:
        #     st.serialize_element(element)

        # st.end()

        comptime assert conforms_to(Seq.IteratorType[origin_of(v)], Base), (
            "Cannot serialize sequence with non-movable or non-implicitly"
            " deletable element type"
        )

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
            st.serialize_element(trait_downcast_var[Base](element^))
        st.end()

    def serialize_struct[T: AnyType](mut self, v: T) raises SerializationError:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "Cannot serialize MLIR type"

        comptime field_count = r.field_count()
        comptime field_names = r.field_names()

        # `Field`-wrapped members may rename themselves or drop out entirely
        # (`skip`), so the emitted count can be smaller than the struct's.
        comptime visible = visible_fields[T]()

        var state = self.begin_struct[r.name()](visible)

        comptime for i in range(field_count):
            comptime FT = r.field_types()[i]
            comptime if not is_skipped[FT]():
                state.serialize_field(
                    wire_name[T, FT](field_names[i]), r.field_ref[i](v)
                )

        state.end()


def serialize[
    T: AnyType, //
](value: T, mut s: Some[Serializer]) raises SerializationError:
    comptime if conforms_to(T, Serializable):
        value.serialize(s)
    else:
        s.serialize_struct(value)
