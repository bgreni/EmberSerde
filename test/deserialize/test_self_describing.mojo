from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    TestSuite,
)
from std.builtin.rebind import rebind_var
from std.utils import Variant

from emberserde.deserialize import (
    Deserializer,
    Deserializable,
    SelfDescribingDeserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import DeserializationError, DerErrorKind
from emberserde.utils import Base
from _token_format import TokenDeserializer


# A purpose-built, primitives-only dynamic value: the smallest thing that can
# stand in for the framework's future `Value` ADT so `SelfDescribingDeserializer`
# has a concrete `Value` to return. One arm per leaf kind this format emits.
struct TinyValue(Copyable, Deserializable, Movable):
    var _v: Variant[Bool, Int64, String]

    @implicit
    def __init__(out self, var v: Bool):
        self._v = v

    @implicit
    def __init__(out self, var v: Int64):
        self._v = v

    @implicit
    def __init__(out self, var v: String):
        self._v = v

    def is_bool(self) -> Bool:
        return self._v.isa[Bool]()

    def is_int(self) -> Bool:
        return self._v.isa[Int64]()

    def is_string(self) -> Bool:
        return self._v.isa[String]()

    def as_bool(self) -> Bool:
        return self._v.unsafe_get[Bool]()

    def as_int(self) -> Int64:
        return self._v.unsafe_get[Int64]()

    def as_string(self) -> String:
        return self._v.unsafe_get[String]().copy()

    # Mirrors the plan's `Value.deserialize` = `d.deserialize_any()`: a dynamic
    # value asks a self-describing format for whatever shape it finds. The
    # assert fires only when this specialization is instantiated — i.e. at
    # the call site that feeds a non-self-describing format — and doubles as
    # the conformance evidence that makes `deserialize_any` callable.
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), SelfDescribingDeserializer
        ), "TinyValue requires a self-describing deserializer"
        # Sound here because the only self-describing format in scope
        # (`PrimSD`) declares `comptime Value = TinyValue`, so the returned
        # `type_of(d).Value` is already this type.
        return rebind_var[Self](d.deserialize_any())


@fieldwise_init
struct PrimCursor(Movable):
    var toks: List[String]
    var pos: Int

    def next(mut self) raises DeserializationError -> String:
        if self.pos >= len(self.toks):
            raise DeserializationError(
                String("unexpected end of token stream"),
                DerErrorKind.InvalidValue,
            )
        var tok = self.toks[self.pos].copy()
        self.pos += 1
        return tok^


# The container framing is never exercised by the primitives-only proof, so a
# single state struct conforms to all five state traits with stub bodies —
# enough to satisfy `Deserializer`'s comptime members without a real seq/map/
# struct/tuple/enum reader.
def _unsupported() -> DeserializationError:
    return DeserializationError(
        String("primitives-only self-describing format"),
        DerErrorKind.InvalidValue,
    )


struct UnusedState(
    EnumDerState,
    MapDerState,
    SeqDerState,
    StructDerState,
    TupleDerState,
):
    def has_next(mut self) raises DeserializationError -> Bool:
        raise _unsupported()

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        raise _unsupported()

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        raise _unsupported()

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        raise _unsupported()

    def expect_field_name(
        mut self,
    ) raises DeserializationError -> Optional[String]:
        raise _unsupported()

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        raise _unsupported()

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        raise _unsupported()

    def variant_index(mut self) raises DeserializationError -> Int:
        raise _unsupported()

    def skip_value(mut self) raises DeserializationError:
        raise _unsupported()

    def end(mut self) raises DeserializationError:
        raise _unsupported()


# Wire form: each value is a `[tag, payload]` token pair where `tag` names the
# leaf kind (`b`/`i`/`s`). The tag makes the wire self-describing, so
# `deserialize_any` can recover the shape with no type info from the caller.
@fieldwise_init
struct PrimSD[origin: MutOrigin](SelfDescribingDeserializer):
    var cursor: Pointer[PrimCursor, Self.origin]

    comptime SeqType = UnusedState
    comptime MapType = UnusedState
    comptime StructType = UnusedState
    comptime TupleType = UnusedState
    comptime EnumType = UnusedState
    comptime Value = TinyValue

    # The concrete method already knows the kind, so the tag is consumed and
    # discarded; only `deserialize_any` needs to branch on it.
    def _payload(mut self) raises DeserializationError -> String:
        _ = self.cursor[].next()
        return self.cursor[].next()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        return self._payload() == "true"

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        var v = self._payload()
        try:
            comptime if DT.is_floating_point():
                return atof(v).cast[DT]()
            else:
                return Scalar[DT](atol(v))
        except e:
            raise DeserializationError(
                String("invalid number: '") + v + "'",
                DerErrorKind.TypeMismatch,
            )

    def expect_string(mut self) raises DeserializationError -> String:
        return self._payload()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        raise _unsupported()

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        raise _unsupported()

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        raise _unsupported()

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        raise _unsupported()

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        raise _unsupported()

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        raise _unsupported()

    def deserialize_any(mut self) raises DeserializationError -> TinyValue:
        var tag = self.cursor[].next()
        var payload = self.cursor[].next()
        if tag == "b":
            return TinyValue(payload == "true")
        if tag == "s":
            return TinyValue(payload^)
        if tag == "i":
            try:
                return TinyValue(Int64(atol(payload)))
            except e:
                raise DeserializationError(
                    String("invalid int: '") + payload + "'",
                    DerErrorKind.InvalidValue,
                )
        raise DeserializationError(
            String("unknown type tag: '") + tag + "'",
            DerErrorKind.TypeMismatch,
        )


# Generic over the sub-trait bound: this only compiles if `deserialize_any` is
# reachable through `SelfDescribingDeserializer` alone.
def read_any[
    D: SelfDescribingDeserializer
](mut d: D) raises DeserializationError -> D.Value:
    return d.deserialize_any()


# Proves the inherited `Deserializer` surface is visible on the sub-trait bound:
# `expect_bool` comes from `Deserializer`, `deserialize_any` from the sub-trait.
def peek_bool_then_any[
    D: SelfDescribingDeserializer
](mut d: D) raises DeserializationError -> D.Value:
    _ = d.expect_bool()
    return d.deserialize_any()


def _any_from(var toks: List[String]) raises DeserializationError -> TinyValue:
    var cursor = PrimCursor(toks^, 0)
    var d = PrimSD(cursor=Pointer(to=cursor))
    return d.deserialize_any()


def test_deserialize_any_bool() raises:
    var v = _any_from(["b", "true"])
    assert_true(v.is_bool())
    assert_true(v.as_bool())


def test_deserialize_any_int() raises:
    var v = _any_from(["i", "42"])
    assert_true(v.is_int())
    assert_equal(v.as_int(), Int64(42))


def test_deserialize_any_string() raises:
    var v = _any_from(["s", "hello"])
    assert_true(v.is_string())
    assert_equal(v.as_string(), String("hello"))


def test_read_via_sub_trait_bound() raises:
    var cursor = PrimCursor(["i", "99"], 0)
    var d = PrimSD(cursor=Pointer(to=cursor))
    var v = read_any(d)
    assert_true(v.is_int())
    assert_equal(v.as_int(), Int64(99))


def test_inherited_method_visible_via_sub_trait() raises:
    # First pair feeds `expect_bool` (inherited), second feeds `deserialize_any`.
    var cursor = PrimCursor(["b", "true", "s", "world"], 0)
    var d = PrimSD(cursor=Pointer(to=cursor))
    var v = peek_bool_then_any(d)
    assert_true(v.is_string())
    assert_equal(v.as_string(), String("world"))


def test_value_deserializable_delegates() raises:
    # `deserialize[TinyValue]` routes through `TinyValue.deserialize`, which
    # dispatches to `deserialize_any` because `PrimSD` is self-describing.
    var cursor = PrimCursor(["i", "7"], 0)
    var d = PrimSD(cursor=Pointer(to=cursor))
    var v = deserialize[TinyValue](d)
    assert_true(v.is_int())
    assert_equal(v.as_int(), Int64(7))


def test_conformance_relationships() raises:
    assert_true(conforms_to(PrimSD[MutAnyOrigin], SelfDescribingDeserializer))
    assert_true(conforms_to(PrimSD[MutAnyOrigin], Deserializer))
    # A non-self-describing format is a `Deserializer` but has no shape info to
    # surface, so it must not satisfy the sub-trait.
    assert_true(conforms_to(TokenDeserializer[MutAnyOrigin], Deserializer))
    assert_false(
        conforms_to(TokenDeserializer[MutAnyOrigin], SelfDescribingDeserializer)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
