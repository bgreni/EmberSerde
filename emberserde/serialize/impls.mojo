import emberserde.serialize
from std.collections import Set, Deque, LinkedList, Counter
from std.collections.string import Codepoint
from std.complex import ComplexSIMD
from std.memory import OwnedPointer, ArcPointer
from std.reflection import reflect
from std.utils import Variant
from emberserde.serialize import Serializable, Serializer
from emberserde.error import SerializationError
from emberserde.struct_modifiers import arm_tag


__extension Bool(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bool(self)


__extension String(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(self)


__extension SIMD(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime if Self.length == 1:
            s.serialize_number(rebind[Scalar[Self.dtype]](self))
        else:
            var tup = s.begin_tuple[Self.length]()
            for i in range(Self.length):
                tup.serialize_element(self[i])
            tup.end()


__extension IntLiteral(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(Int64(Int(self)))


__extension FloatLiteral(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(Float64(self))


__extension Optional(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        if self:
            s.serialize_some(self.value())
        else:
            s.serialize_none()


# Externally tagged: the active arm's tag is its `ArmName` (or its type name
# as the fallback), the arm's value the payload. `Self.Ts` (the variant's
# arm-type pack) is what makes this work — `reflect` can't enumerate variant
# arms, but the pack can.
__extension Variant(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime for i in range(Self.Ts.length):
            comptime AT = Self.Ts[i]
            if self.isa[AT]():
                var st = s.begin_enum[reflect[Self].name(), arm_tag[AT]()](
                    UInt32(i)
                )
                st.serialize_payload(self.unsafe_get[AT]())
                st.end()
                return


__extension Codepoint(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(self.to_u32())


__extension ComplexSIMD(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime if Self.length == 1:
            var tup = s.begin_tuple[2]()
            tup.serialize_element(self.re)
            tup.serialize_element(self.im)
            tup.end()
        else:
            var tup = s.begin_tuple[Self.length]()
            for i in range(Self.length):
                tup.serialize_element(Tuple(self.re[i], self.im[i]))
            tup.end()


__extension List(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_seq(self)


__extension Dict(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var m = s.begin_map(len(self))
        for entry in self.items():
            m.serialize_key(entry.key)
            m.serialize_value(entry.value)
        m.end()


__extension Set(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_seq(self)


__extension Deque(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_seq(self)


__extension LinkedList(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_seq(self)


__extension Counter(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var m = s.begin_map(len(self))
        for entry in self.items():
            m.serialize_key(entry.key)
            m.serialize_value(entry.value)
        m.end()


__extension Array(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var tup = s.begin_tuple[Self.length]()
        for i in range(Self.length):
            tup.serialize_element(self[i])
        tup.end()


__extension Tuple(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime length = Self.__len__()
        var seq = s.begin_tuple[length]()
        comptime for i in range(length):
            seq.serialize_element(self[i])
        seq.end()


__extension OwnedPointer(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        emberserde.serialize.serialize(self[], s)


__extension ArcPointer(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        emberserde.serialize.serialize(self[], s)


__extension Pointer(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime assert (
            Self.address_space == AddressSpace.GENERIC
        ), "Cannot serialize pointer with non-generic address space"
        comptime GenericPtr = Pointer[
            Self.T, Self.origin, address_space=AddressSpace.GENERIC
        ]
        emberserde.serialize.serialize(rebind[GenericPtr](self)[], s)


# `StringSlice` is only a comptime alias for `StringSpan` now, and `__extension`
# needs the underlying struct. Covers `StaticString` too, which is just
# `StringSpan[ImmStaticOrigin]`.
# Non-owning view: serialize-only, same precedent as `Pointer`.
__extension StringSpan(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(self)


# Non-owning view: serialize-only. A `Span[Byte]` routes through the byte hook
# (`serialize_bytes`); any other element type rides the wire as a seq.
__extension Span(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime assert (
            Self.address_space == AddressSpace.GENERIC
        ), "Cannot serialize span with non-generic address space"
        # Canonical-name equality stands in for the removed `_type_is_eq`
        # intrinsic; the `rebind` below still hard-checks it.
        comptime if reflect[Self.T].name() == reflect[Byte].name():
            s.serialize_bytes(rebind[Span[Byte, Self.origin]](self))
        else:
            # Rebind to the generic address space, where `Iterable`
            # conformance holds.
            s.serialize_seq(rebind[Span[Self.T, Self.origin]](self))
