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

import emberserde
from emberserde.serialize import (
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
)
from emberserde.deserialize import (
    Deserializer,
    Deserializable,
    SeqDerState,
    MapDerState,
    StructDerState,
)
from emberserde.error import (
    SerializationError,
    DeserializationError,
    DerErrorKind,
)


@fieldwise_init
struct DebugSeq[origin: MutOrigin](SeqSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        var sub = DebugSerializer(out=self.out)
        emberserde.serialize.serialize(v, sub)

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
        emberserde.serialize.serialize(k, sub)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[] += ": "
        var sub = DebugSerializer(out=self.out)
        emberserde.serialize.serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "}"


@fieldwise_init
struct DebugStruct[origin: MutOrigin](StructSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_field(
        mut self, field_name: String, v: Some[AnyType]
    ) raises SerializationError:
        if not self.first:
            self.out[] += ", "
        self.first = False
        self.out[] += field_name
        self.out[] += ": "
        var sub = DebugSerializer(out=self.out)
        emberserde.serialize.serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += " }"


@fieldwise_init
struct DebugSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]

    comptime MapType = DebugMap[Self.origin]
    comptime SeqType = DebugSeq[Self.origin]
    comptime StructType = DebugStruct[Self.origin]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self.out[] += String(v)

    def serialize_string(mut self, v: String) raises SerializationError:
        self.out[] += '"'
        self.out[] += v
        self.out[] += '"'

    def serialize_none(mut self) raises SerializationError:
        self.out[] += "None"

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        self.out[] += "b["
        for i in range(len(v)):
            if i != 0:
                self.out[] += ", "
            self.out[] += String(v[i])
        self.out[] += "]"

    def begin_seq(mut self) -> Self.SeqType:
        self.out[] += "["
        return DebugSeq(out=self.out, first=True)

    def begin_map(mut self) -> Self.MapType:
        self.out[] += "{"
        return DebugMap(out=self.out, first=True)

    def begin_struct[name: String](mut self) -> Self.StructType:
        self.out[] += name
        self.out[] += " { "
        return DebugStruct(out=self.out, first=True)


# Convenience: serialize `value` through a fresh `DebugSerializer` and return
# the rendered string.
def debug_string[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = DebugSerializer(out=Pointer(to=buf))
    emberserde.serialize.serialize(value, s)
    return buf^


# ----------------------------------------------------------------------------
# The deserialize-side counterpart: a `Deserializer` that parses the Rust-Debug
# string back into values, exercising every `Deserializer` / state-struct method.
# Both directions share the same wire form, so the tests round-trip
# `from_debug[T](debug_string(v)) == v`.
#
# The buffer + cursor live in a `DebugCursor` shared across recursion via a safe
# `Pointer[DebugCursor, origin]`, mirroring how `DebugSerializer` threads its
# output buffer.
# ----------------------------------------------------------------------------


def _de_error(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind(0))


@fieldwise_init
struct DebugCursor(Movable):
    var buf: String
    var pos: Int

    def at_end(self) -> Bool:
        return self.pos >= self.buf.byte_length()

    def peek(self) -> Int:
        if self.at_end():
            return -1
        return Int(self.buf.as_bytes()[self.pos])

    def advance(mut self):
        self.pos += 1

    def skip_ws(mut self):
        while not self.at_end() and self.peek() == ord(" "):
            self.advance()

    def _slice(self, start: Int, end: Int) -> String:
        var result = String()
        var bb = self.buf.as_bytes()
        for i in range(start, end):
            result += chr(Int(bb[i]))
        return result^

    def starts_with(self, lit: StringSlice) -> Bool:
        var lb = lit.as_bytes()
        if self.pos + lit.byte_length() > self.buf.byte_length():
            return False
        var bb = self.buf.as_bytes()
        for i in range(lit.byte_length()):
            if bb[self.pos + i] != lb[i]:
                return False
        return True

    def expect_lit(mut self, lit: StringSlice) raises DeserializationError:
        if not self.starts_with(lit):
            raise _de_error(String("expected '") + String(lit) + "'")
        self.pos += lit.byte_length()

    # Read a run of numeric characters: `[-+0-9.eE]`.
    def read_number(mut self) -> String:
        var start = self.pos
        while not self.at_end():
            var c = self.peek()
            var numeric = (
                c == ord("-")
                or c == ord("+")
                or c == ord(".")
                or c == ord("e")
                or c == ord("E")
                or (c >= ord("0") and c <= ord("9"))
            )
            if not numeric:
                break
            self.advance()
        return self._slice(start, self.pos)


@fieldwise_init
struct DebugSeqDe[origin: MutOrigin](SeqDerState):
    var cursor: Pointer[DebugCursor, Self.origin]

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
        return emberserde.deserialize.deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("]")


@fieldwise_init
struct DebugMapDe[origin: MutOrigin](MapDerState):
    var cursor: Pointer[DebugCursor, Self.origin]

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
        return emberserde.deserialize.deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        var sub = DebugDeserializer(cursor=self.cursor)
        return emberserde.deserialize.deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct DebugStructDe[origin: MutOrigin](StructDerState):
    var cursor: Pointer[DebugCursor, Self.origin]

    def expect_field_name(mut self) raises DeserializationError -> String:
        self.cursor[].skip_ws()
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
        var name = self.cursor[]._slice(start, self.cursor[].pos)
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        return name^

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = DebugDeserializer(cursor=self.cursor)
        return emberserde.deserialize.deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct DebugDeserializer[origin: MutOrigin](Deserializer):
    var cursor: Pointer[DebugCursor, Self.origin]

    comptime SeqType = DebugSeqDe[Self.origin]
    comptime MapType = DebugMapDe[Self.origin]
    comptime StructType = DebugStructDe[Self.origin]

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
        var tok = self.cursor[].read_number()
        try:
            comptime if DT.is_floating_point():
                return atof(tok).cast[DT]()
            else:
                return Scalar[DT](atol(tok))
        except e:
            raise _de_error(String("invalid number: '") + tok + "'")

    def expect_string(mut self) raises DeserializationError -> String:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        var start = self.cursor[].pos
        while not self.cursor[].at_end() and self.cursor[].peek() != ord('"'):
            self.cursor[].advance()
        var s = self.cursor[]._slice(start, self.cursor[].pos)
        self.cursor[].expect_lit('"')
        return s^

    def expect_optional[
        T: Movable
    ](mut self) raises DeserializationError -> Optional[T]:
        self.cursor[].skip_ws()
        if self.cursor[].starts_with("None"):
            self.cursor[].expect_lit("None")
            return Optional[T]()
        return Optional[T](emberserde.deserialize.deserialize[T](self))

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("[")
        return DebugSeqDe(cursor=self.cursor)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("{")
        return DebugMapDe(cursor=self.cursor)

    def begin_struct(mut self) raises DeserializationError -> Self.StructType:
        # The struct name precedes `{`; the framing carries no type info the
        # caller needs, so skip up to and including the opening brace.
        while not self.cursor[].at_end() and self.cursor[].peek() != ord("{"):
            self.cursor[].advance()
        self.cursor[].expect_lit("{")
        self.cursor[].skip_ws()
        return DebugStructDe(cursor=self.cursor)


# Convenience: parse `s` through a fresh `DebugDeserializer` and build a `T`.
def from_debug[T: AnyType](var s: String) raises DeserializationError -> T:
    var cursor = DebugCursor(s^, 0)
    var d = DebugDeserializer(cursor=Pointer(to=cursor))
    return emberserde.deserialize.deserialize[T](d)
