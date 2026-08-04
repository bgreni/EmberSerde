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

from emberserde.serialize import (
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.error import SerializationError


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
