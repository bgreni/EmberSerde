# Toy JSON Format Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a toy JSON format (serializer + deserializer + recursive `JsonValue` behind `SelfDescribingDeserializer`) to the test suite as the third example format.

**Architecture:** One helper module `test/_json_format.mojo` following the pointer-handle pattern of `test/_debug_format.mojo` / `test/_token_format.mojo`, plus two test files mirroring the token-format test layout. Built in three tasks: serializer, typed deserializer, then `JsonValue` + `deserialize_any`.

**Tech Stack:** Mojo (nightly, `pixi` env), emberserde traits, `std.testing.TestSuite`.

**Spec:** `docs/superpowers/specs/2026-08-03-toy-json-format-design.md` (approved).

## Global Constraints

- ALWAYS use the `mojo-syntax` skill conventions: `comptime` (not `alias`), `def` with explicit `raises <Type>`, `Self.`-qualified struct params, `std.` import prefix. The repo's two existing formats are the style reference.
- Run a single test file with: `pixi run mojo run -D ASSERT=all -I . -I test <file>` from the repo root. Full suite: `pixi run test`. Format: `pixi run format` (80 cols).
- Never build/rebuild `emberserde.mojoc` — it must not exist during dev.
- Comments explain *why* only; no file-header summaries of test files, no narration. The `_json_format.mojo` header comment is the one allowed explanatory header (both existing formats have one).
- Deserialize tests feed hand-written wire literals, never serializer output (CLAUDE.md rule).
- Serializer output is compact canonical JSON (no whitespace); parser tolerates whitespace.
- Trust `pixi run` builds over IDE/LSP diagnostics — the language server reports spurious import errors in this repo.
- `git commit` may fail with a GPG/pinentry error in non-TTY sessions. If it does, leave the files staged, do NOT pass `--no-gpg-sign`, and report the pending commit to the user.
- Verified facts this plan relies on (do not re-litigate): direct recursive `Variant` arms (`List[Self]`) do NOT compile ("struct has recursive reference to itself"); the wrapper-struct pattern (`JsonArray`/`JsonObject`) + an explicit empty `__deinit__` on `JsonValue` DOES compile and run (probe-verified 2026-08-03). `__del__` is deprecated; use `__deinit__(deinit self)`. Enum arm tags are canonical type names: `Int64` → `SIMD[DType.int64, 1]`, `String` → `String`.

---

### Task 1: JSON serializer + serialize tests

**Files:**
- Create: `test/serialize/test_json_format.mojo`
- Create: `test/_json_format.mojo`

**Interfaces:**
- Consumes: `emberserde.serialize` traits (`Serializer`, `SeqSerState`, `MapSerState`, `StructSerState`, `TupleSerState`, `EnumSerState`, free fn `serialize`), `emberserde.error.SerializationError`.
- Produces: `to_json[T: AnyType, //](value: T) raises SerializationError -> String`; structs `JsonSerializer[origin: MutOrigin]`, `JsonSeqSer/JsonMapSer/JsonStructSer/JsonTupleSer/JsonEnumSer[origin]`; helper `_write_quoted(mut out: String, v: String)`. Task 2/3 reuse all of these.

- [ ] **Step 1: Write the failing test file**

Create `test/serialize/test_json_format.mojo`:

```mojo
from std.testing import assert_equal, TestSuite
from std.utils import Variant
from _json_format import to_json
from emberserde.struct_modifiers import RenameAll, RenamePolicy


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Nested(Copyable, Movable):
    var label: String
    var point: Point
    var note: Optional[Int64]


@fieldwise_init
struct CamelRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var age: Int


def test_primitives() raises:
    assert_equal(to_json(Int(42)), "42")
    assert_equal(to_json(Int(-7)), "-7")
    assert_equal(to_json(True), "true")
    assert_equal(to_json(False), "false")
    assert_equal(to_json(Float64(2.5)), "2.5")
    assert_equal(to_json(String("hi")), '"hi"')


def test_string_escapes() raises:
    assert_equal(to_json(String('say "hi"')), '"say \\"hi\\""')
    assert_equal(to_json(String("a\\b")), '"a\\\\b"')
    assert_equal(to_json(String("a\nb\tc\rd")), '"a\\nb\\tc\\rd"')


def test_seq() raises:
    var l: List[Int] = [1, 2, 3]
    assert_equal(to_json(l), "[1,2,3]")
    var empty = List[Int]()
    assert_equal(to_json(empty), "[]")
    var nested: List[List[Int]] = [[1], [], [2, 3]]
    assert_equal(to_json(nested), "[[1],[],[2,3]]")


def test_map() raises:
    var d: Dict[String, Int] = {"a": 1, "b": 2}
    assert_equal(to_json(d), '{"a":1,"b":2}')
    var empty = Dict[String, Int]()
    assert_equal(to_json(empty), "{}")


def test_map_non_string_keys_are_stringified() raises:
    var d = Dict[Int, Int]()
    d[1] = 10
    d[2] = 20
    assert_equal(to_json(d), '{"1":10,"2":20}')


def test_struct() raises:
    assert_equal(to_json(Point(x=1, y=2)), '{"x":1,"y":2}')
    var some = Nested(
        label=String("n"), point=Point(x=1, y=2), note=Optional[Int64](5)
    )
    assert_equal(to_json(some), '{"label":"n","point":{"x":1,"y":2},"note":5}')
    var none = Nested(label=String("m"), point=Point(x=0, y=0), note=None)
    assert_equal(to_json(none), '{"label":"m","point":{"x":0,"y":0},"note":null}')


def test_struct_rename_all() raises:
    assert_equal(
        to_json(CamelRec(first_name=1, age=2)), '{"firstName":1,"age":2}'
    )


def test_optional() raises:
    assert_equal(to_json(Optional[Int64](5)), "5")
    assert_equal(to_json(Optional[Int64]()), "null")


def test_tuple() raises:
    assert_equal(to_json(Tuple(Int(1), String("hi"))), '[1,"hi"]')


def test_enum() raises:
    var i = Variant[Int64, String](Int64(5))
    assert_equal(to_json(i), '{"SIMD[DType.int64, 1]":5}')
    var s = Variant[Int64, String](String("hi"))
    assert_equal(to_json(s), '{"String":"hi"}')


def test_bytes() raises:
    var data: List[Byte] = [1, 2, 255]
    assert_equal(to_json(Span(data)), "[1,2,255]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/serialize/test_json_format.mojo`
Expected: FAIL to compile — cannot locate module `_json_format`.

- [ ] **Step 3: Write the serializer half of the helper**

Create `test/_json_format.mojo`:

```mojo
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
```

Fallback (only if Step 4 fails to compile on the trait-default `serialize_some` path): add this override to `JsonSerializer` and note the trait-default failure in the final report to the user — per the project rule, a trait that can't serve the format cleanly is a framework finding, not a format problem:

```mojo
    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = JsonSerializer(out=self.out)
        serialize(v, sub)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/serialize/test_json_format.mojo`
Expected: PASS (all tests green).

- [ ] **Step 5: Format and re-verify**

Run: `pixi run format`, then re-run the Step 4 command.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/_json_format.mojo test/serialize/test_json_format.mojo
git commit -m "add toy JSON serializer to test suite

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Typed JSON deserializer + deserialize tests

**Files:**
- Modify: `test/_json_format.mojo` (append deserializer half)
- Create: `test/deserialize/test_json_format.mojo`

**Interfaces:**
- Consumes: Task 1's `JsonSerializer` pattern and file; `emberserde.deserialize` traits (`Deserializer`, `SeqDerState`, `MapDerState`, `StructDerState`, `TupleDerState`, `EnumDerState`, free fn `deserialize`), `emberserde.error` (`DeserializationError`, `DerErrorKind`), `emberserde.utils.Base`, `std.reflection.reflect`.
- Produces: `from_json[T: AnyType](var s: String) raises DeserializationError -> T`; `JsonCursor` (fields `buf: String`, `pos: Int`; methods `at_end/peek/advance/skip_ws/starts_with/expect_lit/read_number/read_string_contents/skip_json_value`); `JsonDeserializer[origin: MutOrigin]` (plain `Deserializer` for now — Task 3 upgrades it); de-state structs `JsonSeqDe/JsonMapDe/JsonStructDe/JsonTupleDe/JsonEnumDe[origin]`; error helpers `_invalid(String)`, `_mismatch(String)`.

- [ ] **Step 1: Write the failing test file**

Create `test/deserialize/test_json_format.mojo` (hand-written wire literals throughout — never serializer output):

```mojo
from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from std.utils import Variant
from _json_format import from_json
from emberserde.error import DerErrorKind
from emberserde.field import Rename
from emberserde.struct_modifiers import (
    RenameAll,
    RenamePolicy,
    DenyUnknownFields,
)


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Record(Copyable, Defaultable, Movable):
    var name: String
    var note: Optional[Int64]

    def __init__(out self):
        self.name = String()
        self.note = None


@fieldwise_init
struct Outer(Copyable, Defaultable, Movable):
    var label: String
    var inner: Point

    def __init__(out self):
        self.label = String()
        self.inner = Point()


@fieldwise_init
struct Strict(Copyable, DenyUnknownFields, Movable):
    var a: Int


@fieldwise_init
struct CamelRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct Renamed(Copyable, Movable):
    var keep_me: Rename[Int, String("kept")]


def test_primitives() raises:
    assert_equal(from_json[Int]("42"), 42)
    assert_equal(from_json[Int]("-7"), -7)
    assert_equal(from_json[Bool]("true"), True)
    assert_equal(from_json[Bool]("false"), False)
    assert_equal(from_json[Float64]("2.5"), 2.5)
    assert_equal(from_json[String]('"hi"'), String("hi"))


def test_string_escapes() raises:
    assert_equal(from_json[String]('"say \\"hi\\""'), String('say "hi"'))
    assert_equal(from_json[String]('"a\\\\b"'), String("a\\b"))
    assert_equal(from_json[String]('"a\\nb\\tc\\rd"'), String("a\nb\tc\rd"))


def test_whitespace_tolerated() raises:
    var r = from_json[List[Int]]("  [ 1 ,\n\t2 ]  ")
    assert_equal(len(r), 2)
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)


def test_seq() raises:
    var r = from_json[List[Int]]("[1,2,3]")
    assert_equal(len(r), 3)
    assert_equal(r[0], 1)
    assert_equal(r[2], 3)
    var empty = from_json[List[Int]]("[]")
    assert_equal(len(empty), 0)
    var nested = from_json[List[List[Int]]]("[[1],[],[2,3]]")
    assert_equal(len(nested), 3)
    assert_equal(nested[2][1], 3)


def test_map() raises:
    var d = from_json[Dict[String, Int]]('{"a":1,"b":2}')
    assert_equal(len(d), 2)
    assert_equal(d["a"], 1)
    assert_equal(d["b"], 2)


def test_map_int_keys_unwrap_quotes() raises:
    var d = from_json[Dict[Int, Int]]('{"1":10,"2":20}')
    assert_equal(d[1], 10)
    assert_equal(d[2], 20)


def test_struct() raises:
    var p = from_json[Point]('{"x":1,"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_nested_struct() raises:
    var o = from_json[Outer]('{"label":"l","inner":{"x":1,"y":2}}')
    assert_equal(o.label, String("l"))
    assert_equal(o.inner.x, 1)
    assert_equal(o.inner.y, 2)


# The junk value nests containers and hides a `}` inside a string, so this
# exercises `skip_json_value`'s bracket balancing and string jumping.
def test_struct_unknown_field_skipped() raises:
    var p = from_json[Point]('{"x":1,"junk":{"a":[1,{"b":"}"}]},"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_struct_missing_optional_fills_none() raises:
    var r = from_json[Record]('{"name":"n"}')
    assert_equal(r.name, String("n"))
    assert_false(Bool(r.note))


def test_struct_missing_required_raises() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1}')


def test_struct_duplicate_field_raises() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1,"x":2,"y":3}')


def test_deny_unknown_fields_raises() raises:
    with assert_raises():
        _ = from_json[Strict]('{"a":1,"b":2}')


def test_rename_all_matches_wire() raises:
    var r = from_json[CamelRec]('{"firstName":1,"age":2}')
    assert_equal(r.first_name, 1)
    assert_equal(r.age, 2)


def test_field_rename_matches_wire() raises:
    var r = from_json[Renamed]('{"kept":2}')
    assert_equal(r.keep_me.value, 2)


def test_tuple() raises:
    var t = from_json[Tuple[Int, String]]('[1,"hi"]')
    assert_equal(t[0], 1)
    assert_equal(t[1], String("hi"))


def test_optional() raises:
    var some = from_json[Optional[Int64]]("5")
    assert_true(Bool(some))
    assert_equal(some.value(), Int64(5))
    var none = from_json[Optional[Int64]]("null")
    assert_false(Bool(none))


def test_enum_int_arm() raises:
    var r = from_json[Variant[Int64, String]]('{"SIMD[DType.int64, 1]":5}')
    assert_true(r.isa[Int64]())
    assert_equal(r.unsafe_get[Int64](), Int64(5))


def test_enum_string_arm() raises:
    var r = from_json[Variant[Int64, String]]('{"String":"hi"}')
    assert_true(r.isa[String]())
    assert_equal(r.unsafe_get[String](), String("hi"))


def test_enum_unknown_arm_raises() raises:
    with assert_raises():
        _ = from_json[Variant[Int64, String]]('{"Bogus":1}')


def test_malformed_raises() raises:
    with assert_raises():
        _ = from_json[String]('"unterminated')
    with assert_raises():
        _ = from_json[Bool]("tru")
    with assert_raises():
        _ = from_json[Int]('"not a number"')
    with assert_raises():
        _ = from_json[List[Int]]("[1,2")


def test_type_mismatch_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Int]('"str"')
    except e:
        kind = e.kind
    assert_equal(kind._kind, DerErrorKind.TypeMismatch._kind)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/deserialize/test_json_format.mojo`
Expected: FAIL to compile — `from_json` not found in `_json_format`.

- [ ] **Step 3: Append the deserializer half to the helper**

Append to `test/_json_format.mojo`. Also extend the file's imports: add `from std.reflection import reflect`, `from emberserde.deserialize import (Deserializer, SeqDerState, MapDerState, StructDerState, TupleDerState, EnumDerState, deserialize)`, `from emberserde.error import DeserializationError, DerErrorKind` (merge with the existing `SerializationError` import), and `from emberserde.utils import Base`.

```mojo
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
            if depth == 0 and (
                c == ord(",") or c == ord("}") or c == ord("]")
            ):
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/deserialize/test_json_format.mojo`
Expected: PASS.
Also run: `pixi run mojo run -D ASSERT=all -I . -I test test/serialize/test_json_format.mojo`
Expected: still PASS.

- [ ] **Step 5: Format and re-verify**

Run: `pixi run format`, then re-run both Step 4 commands.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add test/_json_format.mojo test/deserialize/test_json_format.mojo
git commit -m "add toy JSON deserializer to test suite

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: `JsonValue` + `SelfDescribingDeserializer` + `deserialize_any`

**Files:**
- Modify: `test/_json_format.mojo` (add value types; upgrade `JsonDeserializer`)
- Modify: `test/deserialize/test_json_format.mojo` (add `deserialize_any`/round-trip/conformance tests)
- Modify: `test/serialize/test_json_format.mojo` (add `JsonValue` serialize test)

**Interfaces:**
- Consumes: Task 1's `to_json` + `Serializer` states, Task 2's `JsonDeserializer` + `from_json`; `SelfDescribingDeserializer`, `Deserializable` from `emberserde.deserialize`; `Serializable` from `emberserde.serialize`; `rebind_var` from `std.builtin.rebind`; `Variant` from `std.utils`.
- Produces: `JsonNull` (empty marker, `Copyable, Movable`), `JsonArray` (field `values: List[JsonValue]`), `JsonObject` (field `entries: Dict[String, JsonValue]`), `JsonValue` (`Copyable, Deserializable, Movable, Serializable`; predicates `is_null/is_bool/is_int/is_float/is_string/is_array/is_object`; accessors `as_bool/as_int/as_float/as_string/as_array/as_object` returning copies); `JsonDeserializer` now conforms to `SelfDescribingDeserializer` with `comptime Value = JsonValue` and `deserialize_any(mut self) raises DeserializationError -> JsonValue`.

- [ ] **Step 1: Add the failing tests**

Append to `test/deserialize/test_json_format.mojo` (and extend its imports: `from _json_format import from_json, to_json, JsonValue, JsonDeserializer`; add `from emberserde.deserialize import Deserializer, SelfDescribingDeserializer`):

```mojo
def test_any_null() raises:
    assert_true(from_json[JsonValue]("null").is_null())


def test_any_bool() raises:
    var v = from_json[JsonValue]("true")
    assert_true(v.is_bool())
    assert_true(v.as_bool())


def test_any_int() raises:
    var v = from_json[JsonValue]("42")
    assert_true(v.is_int())
    assert_equal(v.as_int(), Int64(42))


def test_any_float() raises:
    var v = from_json[JsonValue]("2.5")
    assert_true(v.is_float())
    assert_equal(v.as_float(), Float64(2.5))


def test_any_string() raises:
    var v = from_json[JsonValue]('"hi"')
    assert_true(v.is_string())
    assert_equal(v.as_string(), String("hi"))


def test_any_array() raises:
    var v = from_json[JsonValue]('[1,"two",null]')
    assert_true(v.is_array())
    var arr = v.as_array()
    assert_equal(len(arr), 3)
    assert_equal(arr[0].as_int(), Int64(1))
    assert_equal(arr[1].as_string(), String("two"))
    assert_true(arr[2].is_null())


def test_any_nested_object() raises:
    var v = from_json[JsonValue]('{"a":{"b":[1,true]}}')
    assert_true(v.is_object())
    var inner = v.as_object()["a"].as_object()["b"].as_array()
    assert_equal(inner[0].as_int(), Int64(1))
    assert_true(inner[1].as_bool())


def test_any_malformed_raises() raises:
    with assert_raises():
        _ = from_json[JsonValue]("@")


# Parse → re-serialize → string equality against the hand-written literal:
# insertion-ordered `Dict` keeps object key order stable, so the compact
# canonical form round-trips exactly.
def test_round_trip_through_json_value() raises:
    var src = String('{"a":[1,2.5,true,null,"s\\"x"],"b":{"c":false}}')
    var v = from_json[JsonValue](src.copy())
    assert_equal(to_json(v), src)


def test_conformance() raises:
    assert_true(
        conforms_to(
            JsonDeserializer[MutAnyOrigin], SelfDescribingDeserializer
        )
    )
    assert_true(conforms_to(JsonDeserializer[MutAnyOrigin], Deserializer))
```

Append to `test/serialize/test_json_format.mojo` (extend its import: `from _json_format import to_json, JsonValue, JsonArray, JsonObject, JsonNull`):

```mojo
def test_json_value_serialize() raises:
    var arr = List[JsonValue]()
    arr.append(JsonValue(JsonNull()))
    arr.append(JsonValue(True))
    arr.append(JsonValue(Int64(1)))
    arr.append(JsonValue(String("s")))
    var obj = Dict[String, JsonValue]()
    obj[String("k")] = JsonValue(JsonArray(values=arr^))
    assert_equal(
        to_json(JsonValue(JsonObject(entries=obj^))),
        '{"k":[null,true,1,"s"]}',
    )
```

- [ ] **Step 2: Run test to verify it fails**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/deserialize/test_json_format.mojo`
Expected: FAIL to compile — `JsonValue` not found in `_json_format`.

- [ ] **Step 3: Implement `JsonValue` and upgrade the deserializer**

In `test/_json_format.mojo`:

(a) Extend imports: add `from std.builtin.rebind import rebind_var`, `from std.utils import Variant`; add `Serializable` to the `emberserde.serialize` import; add `Deserializable` and `SelfDescribingDeserializer` to the `emberserde.deserialize` import.

(b) Insert the value types between the serializer section and the deserializer section:

```mojo
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

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime if conforms_to(type_of(d), SelfDescribingDeserializer):
            # Sound because the only self-describing format in scope
            # declares `comptime Value = JsonValue`.
            return rebind_var[Self](d.deserialize_any())
        else:
            raise DeserializationError(
                String("JsonValue requires a self-describing deserializer"),
                DerErrorKind.InvalidValue,
            )

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
```

(c) Upgrade `JsonDeserializer`: change its conformance from `(Deserializer)` to `(SelfDescribingDeserializer)`, add `comptime Value = JsonValue` after the five state-type members, and add `deserialize_any` as the last method:

```mojo
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
        try:
            if is_float:
                return JsonValue(atof(tok))
            return JsonValue(Int64(atol(tok)))
        except e:
            raise _invalid(String("invalid number: '") + tok + "'")
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pixi run mojo run -D ASSERT=all -I . -I test test/deserialize/test_json_format.mojo`
Expected: PASS.
Run: `pixi run mojo run -D ASSERT=all -I . -I test test/serialize/test_json_format.mojo`
Expected: PASS.

- [ ] **Step 5: Run the full precommit gate**

Run: `pixi run precommit`
Expected: formatting applied cleanly and the ENTIRE suite passes (this also proves the new helper module didn't break other test files' imports).

- [ ] **Step 6: Commit**

```bash
git add test/_json_format.mojo test/deserialize/test_json_format.mojo test/serialize/test_json_format.mojo
git commit -m "add JsonValue and SelfDescribing support to toy JSON format

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
