import emberserde
from std.builtin.rebind import downcast, rebind_var
from std.collections import Set, Deque, LinkedList, Counter
from std.collections.string import Codepoint
from std.complex import ComplexSIMD
from std.memory import OwnedPointer, ArcPointer
from std.os import abort
from std.reflection import reflect
from std.utils import Variant
from emberserde.deserialize import Deserializer
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.utils import Base


# Drop helper for retiring a partially-built collection on an error-unwind path.
# `List`/`Dict` are `@explicit_destroy`, so a `var` of a generic element type
# cannot be implicitly destroyed — but a value statically known to be
# `ImplicitlyDeletable` can just fall out of scope here.
def _drop_deletable[T: ImplicitlyDeletable](var x: T):
    pass


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
            var tup = d.begin_tuple[Self.size]()
            for i in range(Self.size):
                result[i] = tup.expect_element[Scalar[Self.dtype]]()
            tup.end()
            return result


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


__extension Variant(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var arm_names = List[String]()
        comptime for i in range(Self.Ts.size):
            arm_names.append(String(reflect[Self.Ts[i]].name()))

        var st = d.begin_enum[Self](arm_names^)
        var idx = st.variant_index()
        comptime for i in range(Self.Ts.size):
            comptime AT = downcast[Self.Ts[i], Base]
            if idx == i:
                var payload = st.expect_payload[AT]()
                st.end()
                return Self(payload^)
        raise DeserializationError(
            String(t"unknown variant index: {idx}"),
            DerErrorKind.UnknownVariant,
        )


__extension Codepoint(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var cp = Codepoint.from_u32(d.expect_number[DType.uint32]())
        if not cp:
            raise DeserializationError(
                "not a valid Unicode scalar value",
                DerErrorKind.InvalidValue,
            )
        return cp.value()


__extension ComplexSIMD(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime if Self.size == 1:
            var tup = d.begin_tuple[2]()
            var re = tup.expect_element[Scalar[Self.dtype]]()
            var im = tup.expect_element[Scalar[Self.dtype]]()
            tup.end()
            return Self(re, im)
        else:
            comptime Pair = Tuple[Scalar[Self.dtype], Scalar[Self.dtype]]
            var re = Self.element_type(0)
            var im = Self.element_type(0)
            var tup = d.begin_tuple[Self.size]()
            for i in range(Self.size):
                var pair = tup.expect_element[Pair]()
                re[i] = pair[0]
                im[i] = pair[1]
            tup.end()
            return Self(re, im)


__extension List(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        try:
            var seq = d.begin_seq()
            while seq.has_next():
                result.append(seq.expect_element[Self.T]())
            seq.end()
        except e:
            comptime if conforms_to(Self.T, ImplicitlyDeletable):
                result^.destroy_with(
                    _drop_deletable[downcast[Self.T, ImplicitlyDeletable]]
                )
            else:
                comptime assert (
                    False
                ), "List deserialize requires ImplicitlyDeletable elements"
            raise e^
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


__extension Set(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var seq = d.begin_seq()
        while seq.has_next():
            result.add(seq.expect_element[Self.T]())
        seq.end()
        return result^


__extension Deque(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var seq = d.begin_seq()
        while seq.has_next():
            result.append(seq.expect_element[Self.ElementType]())
        seq.end()
        return result^


__extension LinkedList(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var seq = d.begin_seq()
        while seq.has_next():
            result.append(seq.expect_element[Self.ElementType]())
        seq.end()
        return result^


__extension Counter(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var m = d.begin_map()
        while m.has_next():
            var k = m.expect_key[Self.V]()
            result[k^] = m.expect_value[Int]()
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

        comptime for i in range(Self.__len__()):
            comptime ET = downcast[Self.element_types[i], Base]
            trait_downcast[Base](result[i]) = state.expect_element[ET]()

        state.end()

        return result^


__extension OwnedPointer(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return rebind_var[Self](
            OwnedPointer(
                emberserde.deserialize.deserialize[downcast[Self.T, Movable]](d)
            )
        )


__extension ArcPointer(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(emberserde.deserialize.deserialize[Self.T](d))
