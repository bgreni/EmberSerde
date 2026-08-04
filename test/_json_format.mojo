# A non-shipping, test-only toy JSON format — the third example format, and
# the first fully self-describing one: `JsonDeserializer` implements
# `SelfDescribingDeserializer` with a recursive `JsonValue` behind
# `deserialize_any` (`test_self_describing.mojo` proves the trait mechanics
# with a primitives-only value; this format proves arbitrary nesting).
# Correctness over performance; string fidelity is ASCII-only (same tradeoff
# as `DebugCursor._slice`) with a minimal escape set (\" \\ \n \t \r).
#
# Wire form: compact canonical JSON out, whitespace-tolerant in. Structs and
# maps are `{...}` with names/keys on the wire; seqs and tuples are `[...]`;
# enums are externally tagged `{"Arm":payload}`; a present `Optional` is the
# bare payload and `None` is `null`; bytes are an array of numbers.
# Non-string map keys are stringified (quoted) on write and unwrapped from
# their quotes on read, serde_json-style. It follows the same pointer-handle
# pattern as the other two formats.

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
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    DeserializationError,
    DerErrorKind,
)
from emberserde.utils import Base


def _write_quoted(mut out: String, v: String):
    out += '"'
    for cp in v.codepoint_slices():
        if cp == '"':
            out += '\\"'
        elif cp == "\\":
            out += "\\\\"
        elif cp == "\n":
            out += "\\n"
        elif cp == "\t":
            out += "\\t"
        elif cp == "\r":
            out += "\\r"
        else:
            out += String(cp)
    out += '"'


@fieldwise_init
struct JsonSeqSer[origin: MutOrigin](SeqSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ","
        self.first = False
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "]"


@fieldwise_init
struct JsonMapSer[origin: MutOrigin](MapSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ","
        self.first = False
        # Stringify non-string keys (serde_json behavior): render the key
        # into a scratch buffer, wrap in quotes unless it already is a string.
        var keybuf = String()
        var sub = JsonSerializer(out=Pointer(to=keybuf))
        serialize(k, sub)
        if keybuf.byte_length() > 0 and Int(keybuf.as_bytes()[0]) == ord('"'):
            self.out[] += keybuf
        else:
            self.out[] += '"'
            self.out[] += keybuf
            self.out[] += '"'

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[] += ":"
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "}"


@fieldwise_init
struct JsonStructSer[origin: MutOrigin](StructSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_field(
        mut self, field_name: String, v: Some[AnyType]
    ) raises SerializationError:
        if not self.first:
            self.out[] += ","
        self.first = False
        _write_quoted(self.out[], field_name)
        self.out[] += ":"
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "}"


@fieldwise_init
struct JsonTupleSer[origin: MutOrigin](TupleSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ","
        self.first = False
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "]"


@fieldwise_init
struct JsonEnumSer[origin: MutOrigin](EnumSerState):
    var out: Pointer[String, Self.origin]

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "}"


@fieldwise_init
struct JsonSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]

    comptime MapType = JsonMapSer[Self.origin]
    comptime SeqType = JsonSeqSer[Self.origin]
    comptime StructType = JsonStructSer[Self.origin]
    comptime TupleType = JsonTupleSer[Self.origin]
    comptime EnumType = JsonEnumSer[Self.origin]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self.out[] += String(v)

    def serialize_string(mut self, v: String) raises SerializationError:
        _write_quoted(self.out[], v)

    def serialize_none(mut self) raises SerializationError:
        self.out[] += "null"

    # `serialize_some` is intentionally NOT overridden: JSON is transparent
    # about presence, which is exactly the trait's default — leaving it off
    # exercises that default for the first time.

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        self.out[] += "["
        for i in range(len(v)):
            if i != 0:
                self.out[] += ","
            self.out[] += String(v[i])
        self.out[] += "]"

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        # Self-describing output: the size hint is not needed.
        self.out[] += "["
        return JsonSeqSer(out=self.out, first=True)

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        self.out[] += "{"
        return JsonMapSer(out=self.out, first=True)

    def begin_struct[
        name: String
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        # Unlike the debug format, JSON does not write the struct name.
        self.out[] += "{"
        return JsonStructSer(out=self.out, first=True)

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        self.out[] += "["
        return JsonTupleSer(out=self.out, first=True)

    def begin_enum[
        name: String, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        self.out[] += "{"
        _write_quoted(self.out[], variant)
        self.out[] += ":"
        return JsonEnumSer(out=self.out)


def to_json[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = JsonSerializer(out=Pointer(to=buf))
    serialize(value, s)
    return buf^


def _invalid(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.InvalidValue)


def _mismatch(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.TypeMismatch)


@fieldwise_init
struct JsonCursor(Movable):
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
        while not self.at_end():
            var c = self.peek()
            if (
                c == ord(" ")
                or c == ord("\t")
                or c == ord("\n")
                or c == ord("\r")
            ):
                self.advance()
            else:
                break

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
            raise _invalid(String("expected '") + String(lit) + "'")
        self.pos += lit.byte_length()

    def read_number(mut self) -> String:
        var result = String()
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
            result += chr(c)
            self.advance()
        return result^

    # Opening quote already consumed; consumes the closing quote.
    def read_string_contents(mut self) raises DeserializationError -> String:
        var result = String()
        while True:
            if self.at_end():
                raise _invalid(String("unterminated string"))
            var c = self.peek()
            if c == ord('"'):
                self.advance()
                return result^
            if c == ord("\\"):
                self.advance()
                if self.at_end():
                    raise _invalid(String("unterminated escape"))
                var e = self.peek()
                if e == ord('"'):
                    result += '"'
                elif e == ord("\\"):
                    result += "\\"
                elif e == ord("n"):
                    result += "\n"
                elif e == ord("t"):
                    result += "\t"
                elif e == ord("r"):
                    result += "\r"
                else:
                    raise _invalid(
                        String("unsupported escape: '\\") + chr(e) + "'"
                    )
                self.advance()
            else:
                result += chr(c)
                self.advance()

    # Skip one whole value: scan to the next `,`/`}`/`]` at depth zero,
    # balancing brackets/braces and jumping over strings (with escapes).
    def skip_json_value(mut self):
        var depth = 0
        while not self.at_end():
            var c = self.peek()
            if depth == 0 and (c == ord(",") or c == ord("}") or c == ord("]")):
                return
            if c == ord('"'):
                self.advance()
                while not self.at_end() and self.peek() != ord('"'):
                    if self.peek() == ord("\\"):
                        self.advance()
                    self.advance()
            elif c == ord("[") or c == ord("{"):
                depth += 1
            elif c == ord("]") or c == ord("}"):
                depth -= 1
            self.advance()


@fieldwise_init
struct JsonSeqDe[origin: MutOrigin](SeqDerState):
    var cursor: Pointer[JsonCursor, Self.origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("]"):
            return False
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        return True

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = JsonDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("]")


@fieldwise_init
struct JsonMapDe[origin: MutOrigin](MapDerState):
    var cursor: Pointer[JsonCursor, Self.origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("}"):
            return False
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        return True

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        comptime if reflect[T].base_name() == "String":
            var sub = JsonDeserializer(cursor=self.cursor)
            return deserialize[T](sub)
        else:
            # Keys ride the wire as JSON strings (serde_json's stringify):
            # unwrap the quotes and parse the contents as a bare value.
            self.cursor[].expect_lit('"')
            var contents = self.cursor[].read_string_contents()
            var kcursor = JsonCursor(contents^, 0)
            var sub = JsonDeserializer(cursor=Pointer(to=kcursor))
            return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        var sub = JsonDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct JsonStructDe[origin: MutOrigin](StructDerState):
    var cursor: Pointer[JsonCursor, Self.origin]

    def expect_field_name(
        mut self,
    ) raises DeserializationError -> Optional[String]:
        self.cursor[].skip_ws()
        if self.cursor[].peek() == ord("}"):
            # End of struct: leave the `}` for `end()` to consume.
            return None
        if self.cursor[].peek() == ord(","):
            self.cursor[].advance()
            self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        var name = self.cursor[].read_string_contents()
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        return name^

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = JsonDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].skip_json_value()

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct JsonTupleDe[origin: MutOrigin](TupleDerState):
    var cursor: Pointer[JsonCursor, Self.origin]
    var first: Bool

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        self.cursor[].skip_ws()
        if not self.first:
            self.cursor[].expect_lit(",")
            self.cursor[].skip_ws()
        self.first = False
        var sub = JsonDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("]")


@fieldwise_init
struct JsonEnumDe[origin: MutOrigin](EnumDerState):
    var cursor: Pointer[JsonCursor, Self.origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = JsonDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("}")


@fieldwise_init
struct JsonDeserializer[origin: MutOrigin](Deserializer):
    var cursor: Pointer[JsonCursor, Self.origin]

    comptime SeqType = JsonSeqDe[Self.origin]
    comptime MapType = JsonMapDe[Self.origin]
    comptime StructType = JsonStructDe[Self.origin]
    comptime TupleType = JsonTupleDe[Self.origin]
    comptime EnumType = JsonEnumDe[Self.origin]

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self.cursor[].skip_ws()
        if self.cursor[].starts_with("true"):
            self.cursor[].expect_lit("true")
            return True
        if self.cursor[].starts_with("false"):
            self.cursor[].expect_lit("false")
            return False
        raise _mismatch(String("expected a boolean"))

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        self.cursor[].skip_ws()
        var tok = self.cursor[].read_number()
        if tok.byte_length() == 0:
            raise _mismatch(String("expected a number"))
        try:
            comptime if DT.is_floating_point():
                return atof(tok).cast[DT]()
            else:
                return Scalar[DT](atol(tok))
        except e:
            raise _mismatch(String("invalid number: '") + tok + "'")

    def expect_string(mut self) raises DeserializationError -> String:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        return self.cursor[].read_string_contents()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        self.cursor[].skip_ws()
        if self.cursor[].starts_with("null"):
            self.cursor[].expect_lit("null")
            return Optional[T]()
        return Optional[T](deserialize[T](self))

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("[")
        return JsonSeqDe(cursor=self.cursor)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("{")
        return JsonMapDe(cursor=self.cursor)

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Field names are read off the wire, so `T` is unused; the
        # framework's reflection default drives the name-matching loop.
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("{")
        return JsonStructDe(cursor=self.cursor)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("[")
        return JsonTupleDe(cursor=self.cursor, first=True)

    # Externally tagged `{"Arm":payload}`: consume up to and including the
    # `:`, resolve the arm name to an index; the closing `}` is `end`'s job.
    def begin_enum[
        T: AnyType
    ](
        mut self, arm_names: List[String]
    ) raises DeserializationError -> Self.EnumType:
        self.cursor[].skip_ws()
        self.cursor[].expect_lit("{")
        self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        var name = self.cursor[].read_string_contents()
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        var idx = -1
        for i in range(len(arm_names)):
            if arm_names[i] == name:
                idx = i
                break
        return JsonEnumDe(cursor=self.cursor, idx=idx)

    # `expect_struct` is intentionally NOT implemented: the framework's
    # reflection-driven default on `Deserializer` drives the framing above.


def from_json[T: AnyType](var s: String) raises DeserializationError -> T:
    var cursor = JsonCursor(s^, 0)
    var d = JsonDeserializer(cursor=Pointer(to=cursor))
    return deserialize[T](d)
