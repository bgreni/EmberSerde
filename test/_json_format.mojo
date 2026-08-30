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
# pattern as the other two formats. Like the debug format, the parser is
# lenient about element commas: missing or leading commas inside a container
# are tolerated rather than rejected.

from std.builtin.rebind import rebind_var
from std.collections.string.string_span import get_static_string
from std.reflection import reflect
from std.utils import Variant

from emberserde.serialize import (
    Serializer,
    Serializable,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializer,
    Deserializable,
    RawKind,
    SelfDescribingDeserializer,
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
    DerErrorKind,
)
from emberserde.utils import Base


def _write_quoted(mut out: String, v: StringSlice):
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
        mut self, field_name: StringSlice, v: Some[AnyType]
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

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
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


struct JsonNull(Copyable, Movable):
    def __init__(out self):
        pass


@fieldwise_init
struct JsonArray(Copyable, Movable):
    var values: List[JsonValue]


@fieldwise_init
struct JsonObject(Copyable, Movable):
    var entries: Dict[String, JsonValue]


# The format's `comptime Value` on `SelfDescribingDeserializer` — per-format
# by decision (no shared framework ADT); structurally what EmberJson's
# `Value` will be.
struct JsonValue(Copyable, Deserializable, Movable, Serializable):
    var _v: Variant[
        JsonNull, Bool, Int64, Float64, String, JsonArray, JsonObject
    ]

    # Mutually recursive with `JsonArray`/`JsonObject`, so the compiler
    # cannot prove implicit deletability on its own; the explicit (empty)
    # destructor breaks the cycle — fields are still destroyed automatically
    # after it runs (EmberJson's `Value` uses the same trick).
    def __deinit__(deinit self):
        pass

    @implicit
    def __init__(out self, var v: JsonNull):
        self._v = v^

    @implicit
    def __init__(out self, var v: Bool):
        self._v = v

    @implicit
    def __init__(out self, var v: Int64):
        self._v = v

    @implicit
    def __init__(out self, var v: Float64):
        self._v = v

    @implicit
    def __init__(out self, var v: String):
        self._v = v^

    @implicit
    def __init__(out self, var v: JsonArray):
        self._v = v^

    @implicit
    def __init__(out self, var v: JsonObject):
        self._v = v^

    def is_null(self) -> Bool:
        return self._v.isa[JsonNull]()

    def is_bool(self) -> Bool:
        return self._v.isa[Bool]()

    def is_int(self) -> Bool:
        return self._v.isa[Int64]()

    def is_float(self) -> Bool:
        return self._v.isa[Float64]()

    def is_string(self) -> Bool:
        return self._v.isa[String]()

    def is_array(self) -> Bool:
        return self._v.isa[JsonArray]()

    def is_object(self) -> Bool:
        return self._v.isa[JsonObject]()

    def as_bool(self) -> Bool:
        return self._v.unsafe_get[Bool]()

    def as_int(self) -> Int64:
        return self._v.unsafe_get[Int64]()

    def as_float(self) -> Float64:
        return self._v.unsafe_get[Float64]()

    def as_string(self) -> String:
        return self._v.unsafe_get[String]().copy()

    def as_array(self) -> List[JsonValue]:
        return self._v.unsafe_get[JsonArray]().values.copy()

    def as_object(self) -> Dict[String, JsonValue]:
        return self._v.unsafe_get[JsonObject]().entries.copy()

    # The assert fires only when this specialization is instantiated — i.e.
    # at the call site that feeds a non-self-describing format — and doubles
    # as the conformance evidence that makes `deserialize_any` callable.
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), SelfDescribingDeserializer
        ), "JsonValue requires a self-describing deserializer"
        # Sound because the only self-describing format in scope
        # declares `comptime Value = JsonValue`.
        return rebind_var[Self](d.deserialize_any())

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        if self._v.isa[JsonNull]():
            s.serialize_none()
        elif self._v.isa[Bool]():
            s.serialize_bool(self._v.unsafe_get[Bool]())
        elif self._v.isa[Int64]():
            s.serialize_number(self._v.unsafe_get[Int64]())
        elif self._v.isa[Float64]():
            s.serialize_number(self._v.unsafe_get[Float64]())
        elif self._v.isa[String]():
            s.serialize_string(self._v.unsafe_get[String]())
        elif self._v.isa[JsonArray]():
            ref arr = self._v.unsafe_get[JsonArray]().values
            var st = s.begin_seq(len(arr))
            for i in range(len(arr)):
                st.serialize_element(arr[i])
            st.end()
        else:
            ref obj = self._v.unsafe_get[JsonObject]().entries
            var st = s.begin_map(len(obj))
            for entry in obj.items():
                st.serialize_key(entry.key)
                st.serialize_value(entry.value)
            st.end()


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

    def _slice(self, start: Int, end: Int) -> String:
        return String(
            StringSlice(unsafe_from_utf8=self.buf.as_bytes()[start:end])
        )

    # Opening quote already consumed; consumes the closing quote. Plain bytes
    # are appended as whole runs (per-byte `chr()` would mangle multi-byte
    # UTF-8); only escapes interrupt a run.
    def read_string_contents(mut self) raises DeserializationError -> String:
        var result = String()
        var run_start = self.pos
        while True:
            if self.at_end():
                raise _invalid(String("unterminated string"))
            var c = self.peek()
            if c == ord('"'):
                result += self._slice(run_start, self.pos)
                self.advance()
                return result^
            if c == ord("\\"):
                result += self._slice(run_start, self.pos)
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
                run_start = self.pos
            else:
                self.advance()

    # --- borrowing support -------------------------------------------------
    # These consume a token without building a `String`, so `raw_bytes` can
    # hand back a span aliasing `buf`.

    def raw_span(self, start: Int, end: Int) -> Span[Byte, ImmUntrackedOrigin]:
        # Origin-erased at the trait boundary; the borrowing type re-ties it.
        return rebind[Span[Byte, ImmUntrackedOrigin]](
            self.buf.as_bytes()[start:end]
        )

    # Opening quote NOT yet consumed; consumes through the closing quote.
    def skip_string_token(mut self) raises DeserializationError:
        self.advance()
        while True:
            if self.at_end():
                raise _invalid(String("unterminated string"))
            var c = self.peek()
            self.advance()
            if c == ord('"'):
                return
            if c == ord("\\"):
                if self.at_end():
                    raise _invalid(String("unterminated escape"))
                self.advance()

    def skip_number_token[
        integer_only: Bool
    ](mut self) raises DeserializationError:
        var start = self.pos
        var fractional = False
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
            if c == ord(".") or c == ord("e") or c == ord("E"):
                fractional = True
            self.advance()
        if self.pos == start:
            raise _mismatch(String("expected a number"))
        comptime if integer_only:
            if fractional:
                raise _mismatch(String("expected an integer"))

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
struct JsonDeserializer[origin: MutOrigin](
    BorrowingDeserializer, SelfDescribingDeserializer
):
    var cursor: Pointer[JsonCursor, Self.origin]

    comptime SeqType = JsonSeqDe[Self.origin]
    comptime MapType = JsonMapDe[Self.origin]
    comptime StructType = JsonStructDe[Self.origin]
    comptime TupleType = JsonTupleDe[Self.origin]
    comptime EnumType = JsonEnumDe[Self.origin]
    comptime Value = JsonValue

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
        return checked_scalar[DT](tok)

    def expect_string(mut self) raises DeserializationError -> String:
        self.cursor[].skip_ws()
        if self.cursor[].peek() != ord('"'):
            raise _mismatch(String("expected a string"))
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
        if self.cursor[].peek() != ord("["):
            raise _mismatch(String("expected an array"))
        self.cursor[].expect_lit("[")
        return JsonSeqDe(cursor=self.cursor)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        self.cursor[].skip_ws()
        if self.cursor[].peek() != ord("{"):
            raise _mismatch(String("expected an object"))
        self.cursor[].expect_lit("{")
        return JsonMapDe(cursor=self.cursor)

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Field names are read off the wire, so `T` is unused; the
        # framework's reflection default drives the name-matching loop.
        self.cursor[].skip_ws()
        if self.cursor[].peek() != ord("{"):
            raise _mismatch(String("expected an object"))
        self.cursor[].expect_lit("{")
        return JsonStructDe(cursor=self.cursor)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self.cursor[].skip_ws()
        if self.cursor[].peek() != ord("["):
            raise _mismatch(String("expected an array"))
        self.cursor[].expect_lit("[")
        return JsonTupleDe(cursor=self.cursor, first=True)

    # Externally tagged `{"Arm":payload}`: consume up to and including the
    # `:`, resolve the arm name to an index; the closing `}` is `end`'s job.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        self.cursor[].skip_ws()
        if self.cursor[].peek() != ord("{"):
            raise _mismatch(String("expected an object"))
        self.cursor[].expect_lit("{")
        self.cursor[].skip_ws()
        self.cursor[].expect_lit('"')
        var name = self.cursor[].read_string_contents()
        self.cursor[].skip_ws()
        self.cursor[].expect_lit(":")
        self.cursor[].skip_ws()
        var idx = -1
        # `comptime for` over the interned candidates: no per-value list.
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and name == an:
                idx = i
        return JsonEnumDe(cursor=self.cursor, idx=idx)

    # Mirrors EmberJson's six `expect_*_bytes` parser entry points: one
    # validated skip, specialised by the kind the caller demands. The span
    # is the token exactly as written, so a string keeps its quotes.
    def raw_bytes[
        kind: RawKind
    ](mut self) raises DeserializationError -> Span[Byte, ImmUntrackedOrigin]:
        self.cursor[].skip_ws()
        var start = self.cursor[].pos

        comptime if kind == RawKind.Str:
            if self.cursor[].peek() != ord('"'):
                raise _mismatch(String("expected a string"))
            self.cursor[].skip_string_token()
        elif kind == RawKind.Integer:
            self.cursor[].skip_number_token[True]()
        elif kind == RawKind.Float:
            self.cursor[].skip_number_token[False]()
        else:
            comptime if kind == RawKind.Seq:
                if self.cursor[].peek() != ord("["):
                    raise _mismatch(String("expected an array"))
            elif kind == RawKind.Map:
                if self.cursor[].peek() != ord("{"):
                    raise _mismatch(String("expected an object"))
            if self.cursor[].at_end():
                raise _invalid(String("expected a JSON value"))
            self.cursor[].skip_json_value()

        return self.cursor[].raw_span(start, self.cursor[].pos)

    # `expect_struct` is intentionally NOT implemented: the framework's
    # reflection-driven default on `Deserializer` drives the framing above.

    def deserialize_any(mut self) raises DeserializationError -> JsonValue:
        self.cursor[].skip_ws()
        var c = self.cursor[].peek()
        if c == ord("n"):
            self.cursor[].expect_lit("null")
            return JsonValue(JsonNull())
        if c == ord("t") or c == ord("f"):
            return JsonValue(self.expect_bool())
        if c == ord('"'):
            return JsonValue(self.expect_string())
        if c == ord("["):
            var arr = List[JsonValue]()
            var st = self.begin_seq()
            while st.has_next():
                arr.append(st.expect_element[JsonValue]())
            st.end()
            return JsonValue(JsonArray(values=arr^))
        if c == ord("{"):
            var obj = Dict[String, JsonValue]()
            var st = self.begin_map()
            while st.has_next():
                var k = st.expect_key[String]()
                obj[k^] = st.expect_value[JsonValue]()
            st.end()
            return JsonValue(JsonObject(entries=obj^))
        var tok = self.cursor[].read_number()
        if tok.byte_length() == 0:
            raise _invalid(String("expected a JSON value"))
        var is_float = False
        for cp in tok.codepoint_slices():
            if cp == "." or cp == "e" or cp == "E":
                is_float = True
                break
        if is_float:
            try:
                return JsonValue(atof(tok))
            except e:
                raise _invalid(String("invalid number: '") + tok + "'")
        return JsonValue(checked_scalar[DType.int64](tok))


def from_json[
    T: Deinitable
](var s: String, out result: T) raises DeserializationError:
    var cursor = JsonCursor(s^, 0)
    var d = JsonDeserializer(cursor=Pointer(to=cursor))
    result = deserialize[T](d)
    d.cursor[].skip_ws()
    if not d.cursor[].at_end():
        raise _invalid(String("trailing characters after JSON value"))
