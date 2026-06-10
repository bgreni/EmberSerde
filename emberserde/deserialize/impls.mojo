import emberserde
from emberserde.deserialize import Deserializer
from emberserde.error import DeserializationError, DerErrorKind


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
            for i in range(Self.size):
                result[i] = seq.expect_element[Scalar[Self.dtype]]()
            seq.end()
            return result


__extension Int(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Int(d.expect_number[DType.int]())


__extension IntLiteral(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var parsed = Int(d.expect_number[DType.int]())

        if parsed != Self():
            raise DeserializationError(
                String(t"Expected {Self()}, received {parsed}"),
                DerErrorKind.InvalidValue,
            )

        return Self()


__extension FloatLiteral(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var parsed = Float64(d.expect_number[DType.float64]())

        if parsed != Self():
            raise DeserializationError(
                String(t"Expected {Self()}, received {parsed}"),
                DerErrorKind.InvalidValue,
            )

        return Self()


__extension Optional(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_optional[Self.T]()


__extension List(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var seq = d.begin_seq()
        while seq.has_next():
            result.append(seq.expect_element[Self.T]())
        seq.end()
        return result^


__extension InlineArray(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self(uninitialized=True)
        var seq = d.begin_seq()
        for i in range(Self.size):
            _ = seq.has_next()
            (result.unsafe_ptr() + i).init_pointee_move(
                seq.expect_element[Self.ElementType]()
            )
        seq.end()
        return result^
