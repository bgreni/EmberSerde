import emberserde
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
            var seq = s.begin_seq()
            for i in range(Self.size):
                seq.serialize_element(self[i])
            seq.end()


__extension Int(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(Int64(self))


__extension IntLiteral(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(Int64(Int(self)))


__extension FloatLiteral(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_number(Float64(self))


__extension Optional(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        if self:
            ref v = self.value()
            emberserde.serialize.serialize(v, s)
        else:
            s.serialize_none()


__extension List(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_seq(self)
