import emberserde
from std.collections import Set
from std.memory import OwnedPointer, ArcPointer
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
