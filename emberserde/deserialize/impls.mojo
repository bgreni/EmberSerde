import emberserde.deserialize
from std.builtin.rebind import downcast, rebind_var
from std.collections import Set, Deque, LinkedList, Counter
from std.collections.string import Codepoint
from std.complex import ComplexSIMD
from std.memory import (
    OwnedPointer,
    ArcPointer,
    forget_deinit,
    unsafe_uninit_move_n,
)
from std.os import abort
from std.reflection import reflect
from std.sys.info import size_of
from std.utils import Variant
from emberserde.deserialize import (
    Deserializable,
    Deserializer,
    SeqDerState,
)
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
    @always_inline
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


def _element[
    ET: Base
](mut seq: Some[SeqDerState], idx: Int) raises DeserializationError -> ET:
    try:
        return seq.expect_element[ET]()
    except e:
        _prepend_index(e, idx)
        raise e^


# Out of line for the same reason as `expect_struct`'s error helpers: a
# failure-only path that would otherwise be formatted inline at every site.
@no_inline
def _prepend_index(mut e: DeserializationError, idx: Int):
    e.prepend_path(String(t"[{idx}]"))


# How many elements `List` deserialization stages on the stack before its
# first heap allocation: up to 16, within a ~512-byte frame budget.
def _staged_count[ET: AnyType]() -> Int:
    return max(1, min(16, 512 // max(1, size_of[ET]())))


__extension List(Deserializable):
    @staticmethod
    @always_inline
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
        var seq = d.begin_seq()
        # Empty lists are common (optional-ish arrays) and cost the element
        # loop nothing: settle them here, inline in the caller.
        if not seq.has_next():
            seq.end()
            return rebind_var[Self](List[ET]())
        return rebind_var[Self](_deserialize_items[ET](seq))


# Out of line: `List.deserialize` (and its empty-list check) inlines into
# its caller, often a struct's field reader, where one copy of the element
# loop per list-typed field would cost more than the call.
@no_inline
def _deserialize_items[
    ET: Base
](mut seq: Some[SeqDerState]) raises DeserializationError -> List[ET]:
    """The elements of a sequence whose `has_next` has just returned True,
    through the closing `end`.

    The first elements are staged in stack storage, so a list that fits
    lands in ONE exactly-sized heap allocation instead of the 1, 2, 4, ...
    doubling chain `append` walks from empty -- that chain's reallocations
    dominate deserializing small nested lists. Longer lists spill into the
    heap and grow as usual.
    """
    comptime N = _staged_count[ET]()
    var staged = Array[ET, N](uninitialized=True)
    var count = 0
    var result = List[ET]()
    # One handler for the whole list rather than one per element (as
    # `_element` does): `in_element` marks the failures that happened inside
    # an element, which get its index prepended to their path.
    var in_element = True
    try:
        while True:
            var elem = seq.expect_element[ET]()
            in_element = False
            if len(result) == 0 and count < N:
                staged.unsafe_ptr().unsafe_offset(count).unsafe_write(elem^)
                count += 1
            else:
                if len(result) == 0:
                    result.reserve(2 * N)
                    result.resize(unsafe_uninit_length=count)
                    unsafe_uninit_move_n[overlapping=False](
                        dest=result.unsafe_ptr(),
                        src=staged.unsafe_ptr(),
                        count=count,
                    )
                    count = 0
                result.append(elem^)
            if not seq.has_next():
                break
            in_element = True
        seq.end()
    except e:
        if in_element:
            _prepend_index(e, count + len(result))
        # Only the staged prefix is initialized; letting `staged` drop would
        # run destructors over uninitialized slots.
        for i in range(count):
            staged.unsafe_ptr().unsafe_offset(i).unsafe_deinit_pointee()
        forget_deinit(staged^)
        raise e^
    if count > 0:
        result = List[ET](unsafe_uninit_length=count)
        var dst = result.unsafe_ptr()
        var src = staged.unsafe_ptr()
        for i in range(count):
            dst.unsafe_offset(i).unsafe_write(
                src.unsafe_offset(i).unsafe_take_pointee()
            )
    forget_deinit(staged^)
    return result^


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
        # Entry index, not the key: `K` is not generically Writable. Counted
        # rather than `len(result)` so a repeated key does not shift it.
        var idx = 0
        while m.has_next():
            try:
                var k = m.expect_key[KT]()
                result[k^] = m.expect_value[VT]()
            except e:
                _prepend_index(e, idx)
                raise e^
            idx += 1
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
        # Wire position, not `len(result)`: a duplicate element leaves the
        # set's size behind the element count.
        var idx = 0
        while seq.has_next():
            result.add(_element[ET](seq, idx))
            idx += 1
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
            result.append(_element[ET](seq, len(result)))
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
            result.append(_element[ET](seq, len(result)))
        seq.end()
        return rebind_var[Self](result^)


__extension Counter(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var result = Self()
        var m = d.begin_map()
        var idx = 0
        while m.has_next():
            try:
                var k = m.expect_key[Self.V]()
                result[k^] = m.expect_value[Int]()
            except e:
                _prepend_index(e, idx)
                raise e^
            idx += 1
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
            _prepend_index(e, count)
            raise e^
        return rebind_var[Self](result^)


__extension Tuple(Deserializable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var state = d.begin_tuple[Self.__len__()]()
        comptime assert Self.Ts.all_conforms_to[
            Defaultable
        ](), "Tuple deserialize requires Defaultable elements"
        var result = Self()

        @__parameter
        def dispose[idx: Int](var elt: Self.Ts[idx]):
            _ = rebind_var[downcast[Self.Ts[idx], Base]](elt^)

        var filled = 0
        try:
            comptime for i in range(Self.__len__()):
                comptime assert conforms_to(
                    Self.Ts[i], Base
                ), "Tuple deserialize requires Movable, Deinitable elements"
                comptime ET = downcast[Self.Ts[i], Base]
                result[i] = state.expect_element[ET]()
                filled += 1

            state.end()
        except e:
            result^.deinit_with[dispose]()
            _prepend_index(e, filled)
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
