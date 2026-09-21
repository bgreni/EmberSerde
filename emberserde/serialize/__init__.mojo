from emberserde.utils import unimplemented, Base
from std.reflection import (
    reflect,
)

from .impls import *
from emberserde.error import SerializationError
from emberserde.field_meta import (
    static_wire_name,
    wire_field_names,
    is_skipped,
    has_unique_wire_names,
)


trait Serializable:
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        ...


trait SeqSerState(Deinitable):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait MapSerState(Deinitable):
    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        ...

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait StructSerState(Deinitable):
    # `T` is the struct and `idx` the field's declaration index (position in
    # `reflect[T]`'s fields), so a format can read its own metadata off the
    # field — anything reflection can reach — without the framework knowing
    # that metadata exists. `field_name` is the resolved wire name. A slice:
    # the framework passes comptime-interned wire names, so taking owned
    # `String` would force an allocation per field per record.
    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


# TODO: Perhaps the size of the tuple could be a parameter in the future.
trait TupleSerState(Deinitable):
    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        ...

    def end(mut self) raises SerializationError:
        ...


trait EnumSerState(Deinitable):
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
        unimplemented["serialize_bool"]()

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        unimplemented["serialize_number"]()

    # A slice (not owned `String`) so borrowed sources — `StringSlice`,
    # `StaticString`, comptime names — reach the format without allocating.
    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        unimplemented["serialize_string"]()

    def serialize_none(mut self) raises SerializationError:
        unimplemented["serialize_none"]()

    # A present `Optional` routes through here so the format gets a hook to
    # emit a presence marker before the payload. Self-describing formats
    # (JSON-like) can keep this transparent default; non-self-describing
    # formats (bincode-like) MUST override it to tag the payload, otherwise
    # `Some(v)` and a bare `v` are byte-identical on the wire and
    # `expect_optional` cannot decode unambiguously.
    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        serialize(v, self)

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        unimplemented["serialize_bytes"]()

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

    # The type itself rather than its name — mirroring the deserialize side —
    # so a format that needs the shape before the first value (a header row,
    # field numbers, a column schema) can reflect on it. `field_count` is the
    # number of fields that will actually be emitted, which `Skip` can make
    # smaller than `T`'s own.
    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        ...

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        ...

    # Externally-tagged sum type. `T` is the enum type; `variant` is
    # the active arm's tag (its `ArmName`, or its canonical type name as the
    # fallback); `idx` is the arm's position (the discriminant a binary format
    # would write). Self-describing formats key on `variant`; non-self-
    # describing formats key on `idx`. `idx` is the stable default for real
    # formats — a fallback name tag embeds module paths and stdlib spellings,
    # so it is best treated as debug/diagnostic unless every arm declares an
    # `ArmName`.
    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        ...

    # FRAMEWORK DRIVER, not a format hook: this default body (and
    # `serialize_struct`'s) is the framework's logic riding on the trait for
    # dispatch. A format that overrides it silently opts out of framework
    # semantics (size hints here; skip/rename/wire-name handling in
    # `serialize_struct`) — override the `begin_*`/state hooks instead.
    def serialize_seq[
        Seq: Iterable
    ](mut self, v: Seq) raises SerializationError:
        # TODO: Switch to nice for loop syntax when it works

        # var st = self.begin_seq(size_hint)
        # for ref element in v:
        #     st.serialize_element(element)

        # st.end()

        # The assert doubles as conformance evidence so `element` can be
        # implicitly dropped after the borrow below.
        comptime assert conforms_to(
            Seq.IteratorType[origin_of(v)].Element, Base
        ), (
            "Cannot serialize sequence with non-movable or non-implicitly"
            " deletable element type"
        )

        var size_hint: Optional[Int]
        comptime if conforms_to(Seq, Sized):
            size_hint = len(v)
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
            st.serialize_element(element)
        st.end()

    def serialize_struct[T: AnyType](mut self, v: T) raises SerializationError:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "Cannot serialize MLIR type"
        comptime assert has_unique_wire_names[T](), (
            "two fields resolve to the same wire name (check renames and"
            " rename_all)"
        )

        comptime field_count = r.field_count()
        comptime field_names = r.field_names()

        # `Field`-wrapped members may rename themselves or drop out entirely
        # (`skip`), so the emitted count can be smaller than the struct's.
        comptime visible = len(wire_field_names[T]())

        var state = self.begin_struct[T](visible)

        comptime for i in range(field_count):
            comptime FT = r.field_types()[i]
            comptime if not is_skipped[FT]():
                # Index at comptime so only the one name materializes, not the
                # whole (non-ImplicitlyCopyable) field-names array.
                comptime declared_name = field_names[i]
                state.serialize_field[T, i](
                    static_wire_name[T, FT, declared_name](),
                    r.field_ref[i](v),
                )

        state.end()


def serialize[
    T: AnyType, //
](value: T, mut s: Some[Serializer]) raises SerializationError:
    comptime if conforms_to(T, Serializable):
        value.serialize(s)
    else:
        s.serialize_struct(value)
