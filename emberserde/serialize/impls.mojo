import emberserde
from std.collections import Set, Deque, LinkedList, Counter
from std.collections.string import Codepoint
from std.complex import ComplexSIMD
from std.memory import OwnedPointer, ArcPointer
from std.sys.intrinsics import _type_is_eq
from emberserde.serialize import Serializer
from emberserde.error import SerializationError


__extension Bool(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bool(self)


__extension String(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(self)


__extension SIMD(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime if Self.size == 1:
            s.serialize_number(rebind[Scalar[Self.dtype]](self))
        else:
            var tup = s.begin_tuple[Self.size]()
            for i in range(Self.size):
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

__extension Codepoint(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(self.to_u32())


__extension ComplexSIMD(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime if Self.size == 1:
            var tup = s.begin_tuple[2]()
            tup.serialize_element(self.re)
            tup.serialize_element(self.im)
            tup.end()
        else:
            var tup = s.begin_tuple[Self.size]()
            for i in range(Self.size):
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


__extension InlineArray(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var tup = s.begin_tuple[Self.size]()
        for i in range(Self.size):
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
            Self.type, Self.origin, AddressSpace.GENERIC
        ]
        emberserde.serialize.serialize(rebind[GenericPtr](self)[], s)


# Covers `StaticString` too, which is just `StringSlice[StaticConstantOrigin]`.
# Non-owning view: serialize-only, same precedent as `Pointer`.
__extension StringSlice(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(String(self))


# Non-owning view: serialize-only. A `Span[Byte]` routes through the byte hook
# (`serialize_bytes`); any other element type rides the wire as a seq.
__extension Span(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        comptime if _type_is_eq[Self.T, Byte]():
            s.serialize_bytes(rebind[Span[Byte, Self.origin]](self))
        else:
            s.serialize_seq(self)
