import emberserde
from std.builtin.rebind import downcast
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
            # Tuple mirror of the serialize side: the lane count comes from the
            # type, so there is no length token to read and no `has_next` guard
            # — `begin_tuple` fixes the element count up front.
            var result = Self()
            var tup = d.begin_tuple[Self.size]()
            for i in range(Self.size):
                result[i] = tup.expect_element[Scalar[Self.dtype]]()
            tup.end()
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


__extension Dict(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var m = d.begin_map()
        while m.has_next():
            var k = m.expect_key[Self.K]()
            result[k^] = m.expect_value[Self.V]()
        m.end()
        return result^


__extension InlineArray(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self(uninitialized=True)
        var tup = d.begin_tuple[Self.size]()
        for i in range(Self.size):
            (result.unsafe_ptr() + i).init_pointee_move(
                tup.expect_element[Self.ElementType]()
            )
        tup.end()
        return result^


__extension Tuple(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var state = d.begin_tuple[Self.__len__()]()
        var result = Self()

        # A tuple element ref erases to `AnyType` (like a reflected struct
        # field), so assign through `trait_downcast` to a concrete-enough
        # trait combo — a bare `result[i] = ...` cannot destroy the erased
        # default value it overwrites.
        comptime for i in range(Self.__len__()):
            comptime ET = downcast[
                Self.element_types[i], Movable & ImplicitlyDestructible
            ]
            trait_downcast[Movable & ImplicitlyDestructible](
                result[i]
            ) = state.expect_element[ET]()

        state.end()

        return result^
