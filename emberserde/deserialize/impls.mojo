import emberserde
from emberserde.deserialize import Deserializer
from emberserde.error import DeserializationError


__extension Bool(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_bool()


__extension String(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_string()


__extension SIMD(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime if Self.size == 1:
            return d.expect_number[Self.dtype]()
        else:
            var result = Self()
            var seq = d.begin_seq()
            comptime for i in range(Self.size):
                result[i] = seq.expect_element[Scalar[Self.dtype]]()
            seq.end()
            return result


__extension Int(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Int(d.expect_number[DType.int64]())


__extension Optional(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(Self.T, Deserializable)
        return d.expect_optional[Self.T]()


__extension List(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(Self.T, Deserializable)
        var result = Self()
        var seq = d.begin_seq()
        while seq.has_next():
            result.append(seq.expect_element[Self.T]())
        seq.end()
        return result^
