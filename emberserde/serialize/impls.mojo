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
            # Fixed-width homogeneous run: the lane count is a compile-time
            # parameter, so it rides as a tuple (no length token on the wire),
            # not a seq. See PLAN.md discussion of seq-vs-tuple.
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


__extension InlineArray(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        # Statically-sized array: length is part of the type, so serialize as
        # a tuple (no length prefix) rather than a seq.
        var tup = s.begin_tuple[Self.size]()
        for i in range(Self.size):
            tup.serialize_element(self[i])
        tup.end()


__extension Tuple(Serializable):
    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        var seq = s.begin_tuple[Self.__len__()]()
        comptime for i in range(Self.__len__()):
            seq.serialize_element(self[i])
        seq.end()
