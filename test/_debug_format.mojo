# A non-shipping, test-only `Serializer` that renders Rust-`Debug`-style
# output, e.g. `Point { x: 1, y: 2 }` or `[1, 2, 3]`.
#
# Its purpose (per PLAN.md step 5.1) is to exercise every method on the
# `Serializer` / state-struct API so trait-design flaws surface before a real
# format is on the line. It is the only `Serializer` the framework "owns".
#
# The `Serializer` trait is origin-agnostic, so the borrow is threaded here
# instead: `DebugSerializer[origin]` is a thin handle holding a safe
# `Pointer[String, origin]` to the output buffer. Its state types are
# `DebugSeq[origin]`/etc., which carry the same safe pointer, and recursion just
# reconstructs a `DebugSerializer[origin]` over the shared buffer. No
# `UnsafePointer`, no erased `MutAnyOrigin`.

from std.collections.string.string_span import get_static_string
from std.reflection import reflect

from emberserde.serialize import (
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.deserialize import (
    Deserializer,
    Deserializable,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    checked_scalar,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    DeserializationError,
)
from emberserde.field_meta import field_index
from emberserde.utils import Base
from _text_utils import TextCursor


@fieldwise_init
struct DebugSeq[origin: MutOrigin](SeqSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "]"


@fieldwise_init
struct DebugMap[origin: MutOrigin](MapSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        var sub = DebugSerializer(out=self.out)
        serialize(k, sub)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[] += ": "
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "}"


@fieldwise_init
struct DebugStruct[origin: MutOrigin](StructSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        self.out[] += field_name
        self.out[] += ": "
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += " }"


@fieldwise_init
struct DebugTuple[origin: MutOrigin](TupleSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += ")"


@fieldwise_init
struct DebugEnum[origin: MutOrigin](EnumSerState):
    var out: Pointer[String, Self.origin]

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += ")"


@fieldwise_init
struct DebugSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]

    comptime MapType = DebugMap[Self.origin]
    comptime SeqType = DebugSeq[Self.origin]
    comptime StructType = DebugStruct[Self.origin]
    comptime TupleType = DebugTuple[Self.origin]
    comptime EnumType = DebugEnum[Self.origin]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self.out[] += String(v)

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self.out[] += '"'
        self.out[] += v
        self.out[] += '"'

    def serialize_none(mut self) raises SerializationError:
        self.out[] += "None"

    # Rust-`Debug`-faithful: a present optional renders as `Some(payload)`,
    # exercising the presence-marker hook a binary format would rely on.
    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[] += "Some("
        var sub = DebugSerializer(out=self.out)
        serialize(v, sub)
        self.out[] += ")"

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        self.out[] += "b["
        for i in range(len(v)):
            if i != 0:
                self.out[] += ", "
            self.out[] += String(v[i])
        self.out[] += "]"

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        # Self-describing output: the size hint is not needed.
        self.out[] += "["
        return DebugSeq(out=self.out, first=True)

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        self.out[] += "{"
        return DebugMap(out=self.out, first=True)

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        self.out[] += reflect[T].name()
        self.out[] += " { "
        return DebugStruct(out=self.out, first=True)

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        self.out[] += "("
        return DebugTuple(out=self.out, first=True)

    # Rust-`Debug`-style: render the active arm as `ArmName(payload)`, mirroring
    # how a present `Optional` renders as `Some(payload)`.
    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        self.out[] += variant
        self.out[] += "("
        return DebugEnum(out=self.out)


def debug_string[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = DebugSerializer(out=Pointer(to=buf))
    serialize(value, s)
    return buf^


# ----------------------------------------------------------------------------
# The deserialize-side counterpart: a `Deserializer` that parses the Rust-Debug
# string back into values, exercising every `Deserializer` / state-struct method.
# Both directions share the same wire form, so the tests round-trip
# `from_debug[T](debug_string(v)) == v`.
#
# The buffer + cursor live in a `TextCursor` shared across recursion via a safe
# `Pointer[TextCursor, origin]`, mirroring how `DebugSerializer` threads its
# output buffer.
# ----------------------------------------------------------------------------


# Skip one whole value: scan to the next `,`/`}`/`]` at nesting depth zero,
# balancing brackets/braces/parens and jumping over strings. Used by
# `skip_value` to ignore unknown struct fields of any shape.
def _skip_balanced(mut c: TextCursor):
    var depth = 0
    while not c.at_end():
        var b = c.peek()
        if depth == 0 and (b == ord(",") or b == ord("}") or b == ord("]")):
            return
        if b == ord('"'):
            c.advance()
            while not c.at_end() and c.peek() != ord('"'):
                c.advance()
        elif b == ord("[") or b == ord("{") or b == ord("("):
            depth += 1
        elif b == ord("]") or b == ord("}") or b == ord(")"):
            depth -= 1
        c.advance()


@fieldwise_init
struct DebugSeqDe[origin: MutOrigin](SeqDerState):
    var cursor: Pointer[TextCursor, Self.origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("]"):
            return False
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        return True

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("]")


@fieldwise_init
struct DebugMapDe[origin: MutOrigin](MapDerState):
    var cursor: Pointer[TextCursor, Self.origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("}"):
            return False
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        return True

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct DebugStructDe[origin: MutOrigin](StructDerState):
    var cursor: Pointer[TextCursor, Self.origin]

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("}"):
            # End of struct: leave the `}` for `end()` to consume.
            return None
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        var start = self.cursor[].pos
        while (
            not self.cursor[].at_end()
            and self.cursor[].peek() != ord(":")
            and self.cursor[].peek() != ord(" ")
        ):
            self.cursor[].advance()
        var name = self.cursor[].slice(start, self.cursor[].pos)
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        return field_index[T](name)

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        _skip_balanced(self.cursor[])

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct DebugTupleDe[origin: MutOrigin](TupleDerState):
    var cursor: Pointer[TextCursor, Self.origin]
    var first: Bool

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        if not self.first:
            self.cursor[].expect_lit(",")
            self.cursor[].skip_ws()
        self.first = False
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(")")


@fieldwise_init
struct DebugEnumDe[origin: MutOrigin](EnumDerState):
    var cursor: Pointer[TextCursor, Self.origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = DebugDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(")")


@fieldwise_init
struct DebugDeserializer[origin: MutOrigin](Deserializer):
    var cursor: Pointer[TextCursor, Self.origin]

    comptime SeqType = DebugSeqDe[Self.origin]
    comptime MapType = DebugMapDe[Self.origin]
    comptime StructType = DebugStructDe[Self.origin]
    comptime TupleType = DebugTupleDe[Self.origin]
    comptime EnumType = DebugEnumDe[Self.origin]

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].starts_with("true"):
            self.cursor[].expect_lit("true")
            return True
        self.cursor[].expect_lit("false")
        return False

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        self.cursor[].skip_ws()
        return checked_scalar[DT](self.cursor[].read_number())

    def expect_bytes(mut self) raises DeserializationError -> List[Byte]:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("b")
        return deserialize[List[Byte]](self)

    def expect_string(mut self) raises DeserializationError -> String:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        var start = self.cursor[].pos
        while not self.cursor[].at_end() and self.cursor[].peek() != ord('"'):
            self.cursor[].advance()
        var s = self.cursor[].slice(start, self.cursor[].pos)
        self.cursor[].expect_lit('"')
        return s^

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        self.cursor[].skip_ws()
        if self.cursor[].starts_with("None"):
            self.cursor[].expect_lit("None")
            return Optional[T]()
        self.cursor[].expect_lit("Some(")
        var result = Optional[T](deserialize[T](self))
        self.cursor[].expect_lit(")")
        return result^

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("[")
        return DebugSeqDe(cursor=self.cursor)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("{")
        return DebugMapDe(cursor=self.cursor)

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Self-describing wire form: field names are read off the text, so
        # `T` is unused. The struct name precedes `{`; the framing carries no
        # type info the caller needs, so skip up to and including the brace.
        while not self.cursor[].at_end() and self.cursor[].peek() != ord("{"):
            self.cursor[].advance()
        self.cursor[].expect_lit("{")
        self.cursor[].skip_ws()
        return DebugStructDe(cursor=self.cursor)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("(")
        return DebugTupleDe(cursor=self.cursor, first=True)

    # Reads the arm-name tag up to the opening `(`, resolves it to an arm index
    # via `arm_names`; the matching `)` is `end`'s job. Only called for
    # `Variant` targets, so no ambiguity with tuples/structs.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        self.cursor[].skip_ws()
        var start = self.cursor[].pos
        while not self.cursor[].at_end() and self.cursor[].peek() != ord("("):
            self.cursor[].advance()
        var name = self.cursor[].slice(start, self.cursor[].pos)
        self.cursor[].expect_lit("(")
        var idx = -1
        # `comptime for` over the interned candidates: no per-value list.
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return DebugEnumDe(cursor=self.cursor, idx=idx)

    # `expect_struct` is intentionally NOT implemented here: the framework's
    # reflection-driven default on `Deserializer` drives the framing above.


def from_debug[T: AnyType](var s: String) raises DeserializationError -> T:
    var cursor = TextCursor(s^, 0)
    var d = DebugDeserializer(cursor=Pointer(to=cursor))
    return deserialize[T](d)
