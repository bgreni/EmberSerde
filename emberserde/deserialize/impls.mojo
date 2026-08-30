import emberserde.deserialize
from std.builtin.rebind import downcast, rebind_var
from std.collections import Set, Deque, LinkedList, Counter
from std.collections.string import Codepoint
from std.complex import ComplexSIMD
from std.memory import OwnedPointer, ArcPointer, forget_deinit
from std.os import abort
from std.reflection import reflect
from std.utils import Variant
from emberserde.deserialize import Deserializable, Deserializer
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.struct_modifiers import arm_tag
from emberserde.utils import Base


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
        comptime if Self.length == 1:
            # `DType.bool` is the one dtype that is not a number in the data
            # model -- it rides the wire as a boolean, exactly as plain `Bool`
            # does. Sending it through `expect_number` rejects `true` and
            # silently accepts `1`.
            comptime if Self.dtype == DType.bool:
                return rebind[Self](Scalar[DType.bool](d.expect_bool()))
            else:
                return d.expect_number[Self.dtype]()
        else:
            var result = Self()
            var tup = d.begin_tuple[Self.length]()
            for i in range(Self.length):
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
        comptime assert conforms_to(
            Self.T, Base
        ), "Optional deserialize requires a Movable, Deinitable payload"
        return rebind_var[Self](d.expect_optional[downcast[Self.T, Base]]())


__extension Variant(Deserializable):
    @staticmethod
    def _serde_arm_names() -> List[String]:
        var names = List[String]()
        comptime for i in range(Self.Ts.length):
            names.append(arm_tag[Self.Ts[i]]())
        return names^

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime arm_names = Self._serde_arm_names()
        var st = d.begin_enum[Self, arm_names]()
        var idx = st.variant_index()
        comptime for i in range(Self.Ts.length):
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
        comptime if Self.length == 1:
            var tup = d.begin_tuple[2]()
            var re = tup.expect_element[Scalar[Self.dtype]]()
            var im = tup.expect_element[Scalar[Self.dtype]]()
            tup.end()
            return Self(re, im)
        else:
            comptime Pair = Tuple[Scalar[Self.dtype], Scalar[Self.dtype]]
            var re = Self.element_type(0)
            var im = Self.element_type(0)
            var tup = d.begin_tuple[Self.length]()
            for i in range(Self.length):
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
        comptime assert conforms_to(
            Self.T, Deinitable
        ), "List deserialize requires Deinitable elements"
        # Build over the downcast element type: `List` is `@explicit_destroy`
        # unless its elements are statically `Deinitable`, and the
        # partially-built list must be droppable when a framing call raises.
        comptime ET = downcast[Self.T, Base]
        var result = List[ET]()
        var seq = d.begin_seq()
        while seq.has_next():
            comptime if type_of(d).track_error_paths:
                try:
                    result.append(seq.expect_element[ET]())
                except e:
                    e.prepend_path(String(t"[{len(result)}]"))
                    raise e^
            else:
                result.append(seq.expect_element[ET]())
        seq.end()
        return rebind_var[Self](result^)


__extension Dict(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(Self.K, Deinitable) and conforms_to(
            Self.V, Deinitable
        ), "Dict deserialize requires Deinitable keys and values"
        comptime KT = downcast[Self.K, KeyElement & Deinitable]
        comptime VT = downcast[Self.V, Base]
        var result = Dict[KT, VT]()
        var m = d.begin_map()
        while m.has_next():
            comptime if type_of(d).track_error_paths:
                # Entry index, not the key: `K` is not generically Writable.
                var idx = len(result)
                try:
                    var k = m.expect_key[KT]()
                    result[k^] = m.expect_value[VT]()
                except e:
                    e.prepend_path(String(t"[{idx}]"))
                    raise e^
            else:
                var k = m.expect_key[KT]()
                result[k^] = m.expect_value[VT]()
        m.end()
        return rebind_var[Self](result^)


__extension Set(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            Self.T, Deinitable
        ), "Set deserialize requires Deinitable elements"
        comptime ET = downcast[Self.T, KeyElement & Deinitable]
        var result = Set[ET]()
        var seq = d.begin_seq()
        while seq.has_next():
            comptime if type_of(d).track_error_paths:
                try:
                    result.add(seq.expect_element[ET]())
                except e:
                    e.prepend_path(String(t"[{len(result)}]"))
                    raise e^
            else:
                result.add(seq.expect_element[ET]())
        seq.end()
        return rebind_var[Self](result^)


__extension Deque(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            Self.ElementType, Deinitable
        ), "Deque deserialize requires Deinitable elements"
        comptime ET = downcast[Self.ElementType, Base]
        var result = Deque[ET]()
        var seq = d.begin_seq()
        while seq.has_next():
            comptime if type_of(d).track_error_paths:
                try:
                    result.append(seq.expect_element[ET]())
                except e:
                    e.prepend_path(String(t"[{len(result)}]"))
                    raise e^
            else:
                result.append(seq.expect_element[ET]())
        seq.end()
        return rebind_var[Self](result^)


__extension LinkedList(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            Self.ElementType, Deinitable
        ), "LinkedList deserialize requires Deinitable elements"
        comptime ET = downcast[Self.ElementType, Base]
        var result = LinkedList[ET]()
        var seq = d.begin_seq()
        while seq.has_next():
            comptime if type_of(d).track_error_paths:
                try:
                    result.append(seq.expect_element[ET]())
                except e:
                    e.prepend_path(String(t"[{len(result)}]"))
                    raise e^
            else:
                result.append(seq.expect_element[ET]())
        seq.end()
        return rebind_var[Self](result^)


__extension Counter(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var m = d.begin_map()
        while m.has_next():
            comptime if type_of(d).track_error_paths:
                var idx = len(result)
                try:
                    var k = m.expect_key[Self.V]()
                    result[k^] = m.expect_value[Int]()
                except e:
                    e.prepend_path(String(t"[{idx}]"))
                    raise e^
            else:
                var k = m.expect_key[Self.V]()
                result[k^] = m.expect_value[Int]()
        m.end()
        return result^


__extension Array(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            Self.T, Base
        ), "Array deserialize requires Movable, Deinitable elements"
        comptime ET = downcast[Self.T, Base]
        var result = Array[ET, Self.length](uninitialized=True)
        # On a mid-array error only the initialized prefix may be destroyed —
        # letting `result` drop would run destructors over uninitialized
        # elements.
        var count = 0
        try:
            var tup = d.begin_tuple[Self.length]()
            for i in range(Self.length):
                result.unsafe_ptr().unsafe_offset(i).unsafe_write(
                    tup.expect_element[ET]()
                )
                count += 1
            tup.end()
        except e:
            for i in range(count):
                result.unsafe_ptr().unsafe_offset(i).unsafe_deinit_pointee()
            forget_deinit(result^)
            comptime if type_of(d).track_error_paths:
                e.prepend_path(String(t"[{count}]"))
            raise e^
        return rebind_var[Self](result^)


__extension Tuple(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var state = d.begin_tuple[Self.__len__()]()
        comptime assert Self.element_types.all_conforms_to[
            Defaultable
        ](), "Tuple deserialize requires Defaultable elements"
        var result = Self()

        @parameter
        def dispose[idx: Int](var elt: Self.element_types[idx]):
            _ = rebind_var[downcast[Self.element_types[idx], Base]](elt^)

        var filled = 0
        try:
            comptime for i in range(Self.__len__()):
                comptime assert conforms_to(
                    Self.element_types[i], Base
                ), "Tuple deserialize requires Movable, Deinitable elements"
                comptime ET = downcast[Self.element_types[i], Base]
                result[i] = state.expect_element[ET]()
                filled += 1

            state.end()
        except e:
            result^.deinit_with[dispose]()
            comptime if type_of(d).track_error_paths:
                e.prepend_path(String(t"[{filled}]"))
            raise e^

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
