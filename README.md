# EmberSerde

[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

A format-agnostic serialization framework for Mojo, inspired by Rust's
[serde](https://github.com/serde-rs/serde) and redesigned around Mojo's type
system. Compile-time reflection replaces derive macros: any plain struct
serializes and deserializes with no code of its own, and a type that needs
custom behaviour conforms to a trait. Formats implement one trait per
direction and get every type for free.

## Installation

Requires **Mojo 1.1.0**. Add the repo as a git dependency
and pixi builds the `.mojoc` for you:

```toml
[dependencies]
emberserde = { git = "https://github.com/bgreni/EmberSerde.git", branch = "main" }
```

## Quick start

A format is a struct conforming to `Serializer`. It implements the primitive
hooks and, for each container kind, a `begin_*` method that returns a state
struct the framework then drives. Below is a complete compact-JSON writer. One
state struct serves all five container kinds because JSON only needs to know
the closing bracket and whether to emit a comma.

```mojo
from emberserde import (
    Serializer, SerializationError, serialize,
    SeqSerState, MapSerState, StructSerState, TupleSerState, EnumSerState,
)


@fieldwise_init
struct JsonSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]

    comptime SeqType = JsonContainer[Self.origin]
    comptime MapType = JsonContainer[Self.origin]
    comptime StructType = JsonContainer[Self.origin]
    comptime TupleType = JsonContainer[Self.origin]
    comptime EnumType = JsonContainer[Self.origin]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self.out[] += String(v)

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self.out[] += '"'
        self.out[] += v  # a real format escapes here
        self.out[] += '"'

    def serialize_none(mut self) raises SerializationError:
        self.out[] += "null"

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        self.out[] += "["
        return JsonContainer(out=self.out, close="]", first=True)

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        self.out[] += "{"
        return JsonContainer(out=self.out, close="}", first=True)

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        self.out[] += "{"
        return JsonContainer(out=self.out, close="}", first=True)

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        self.out[] += "["
        return JsonContainer(out=self.out, close="]", first=True)

    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        self.out[] += '{"'
        self.out[] += variant
        self.out[] += '":'
        return JsonContainer(out=self.out, close="}", first=True)


@fieldwise_init
struct JsonContainer[origin: MutOrigin](
    SeqSerState, MapSerState, StructSerState, TupleSerState, EnumSerState
):
    var out: Pointer[String, Self.origin]
    var close: StaticString
    var first: Bool

    def _separate(mut self):
        if not self.first:
            self.out[] += ","
        self.first = False

    def _write(mut self, v: Some[AnyType]) raises SerializationError:
        var s = JsonSerializer(out=self.out)
        serialize(v, s)

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        self._separate()
        self._write(v)

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        self._separate()
        self._write(k)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        self.out[] += ":"
        self._write(v)

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        self._separate()
        self.out[] += '"'
        self.out[] += field_name
        self.out[] += '":'
        self._write(v)

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        self._write(v)

    def end(mut self) raises SerializationError:
        self.out[] += self.close
```

Nested values recurse through the free function `serialize`, which is also the
public entry point. Wrap the format in a helper and any type goes through it,
including plain structs that have never heard of EmberSerde:

```mojo
def to_json[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = JsonSerializer(out=Pointer(to=buf))
    serialize(value, s)
    return buf^


@fieldwise_init
struct Server(Copyable, Movable):
    var host: String
    var port: Int
    var tags: List[String]
    var retry: Optional[Int]


def main() raises:
    print(to_json(Server("mojo.dev", 443, ["fast", "safe"], None)))
    # {"host":"mojo.dev","port":443,"tags":["fast","safe"],"retry":null}
```

Under the hood `serialize` is a `comptime` branch: a type's own
`Serializable` impl if it has one, otherwise the reflection default that walks
the struct's fields and calls `begin_struct` / `serialize_field`:

```mojo
def serialize[T: AnyType, //](value: T, mut s: Some[Serializer]) raises SerializationError:
    comptime if conforms_to(T, Serializable):
        value.serialize(s)
    else:
        s.serialize_struct(value)
```

The read side is symmetric: a `Deserializer` implements `expect_*` hooks and
`begin_*` methods returning `*DerState` structs, and `deserialize[T](d)` is the
entry point. See [Writing a format](#writing-a-format).

### What the reflection default needs from your struct

- **Serialize:** nothing. Every field must itself be serializable.
- **Deserialize:** the struct must be `Defaultable`, *or* contain only
  trivially-destructible fields (numbers, `Bool`, nested structs of the same).
  A struct holding a `String` or `List` without a zero-arg `__init__` fails at
  compile time with a readable message.

## Customizing

### Hand-written impls

Conform to `Serializable` / `Deserializable` to take over the wire shape
entirely:

```mojo
from emberserde import (
    Serializable, Serializer, SerializationError,
    Deserializable, Deserializer, DeserializationError, checked_scalar,
)


@fieldwise_init
struct Celsius(Copyable, Movable, Serializable, Deserializable):
    var degrees: Float64

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(String(t"{self.degrees}C"))

    @staticmethod
    def deserialize(mut d: Some[Deserializer]) raises DeserializationError -> Self:
        var text = d.expect_string()
        return Self(checked_scalar[DType.float64](String(text.removesuffix("C"))))

# wire: "21.5C"   (not {"degrees": 21.5})
```

`checked_scalar` parses a numeric token into any `DType` and raises on
overflow instead of wrapping.

### Field attributes

Attributes are attached with Mojo's (experimental) `@__annotation` decorator.
Fields keep their own type, so there is nothing to unwrap.

```mojo
from emberserde import Alias, Default, Rename, Skip, Validate


@fieldwise_init
struct User(Copyable, Defaultable, Movable):
    @__annotation(Rename("userName"))
    var name: String

    @__annotation(Skip())
    var debug: Bool

    @__annotation(Default(3), Validate(lambda (x: Int) -> Bool: x >= 0))
    var retries: Int

    @__annotation(Alias("mail"))
    var email: String

    def __init__(out self):
        ...

# out:  {"userName":"ada","retries":3,"email":"a@b.c"}
# in:   {"userName":"ada","mail":"a@b.c"}   -> retries == 3, debug == False
```

| Attribute | Effect |
|---|---|
| `Rename(name)` | Wire name differs from the declared name. |
| `Alias(name)` | Additional name accepted on read. Repeat for more. |
| `Skip` | Never written; filled from the default on read. |
| `Default(value)` | Value used when the field is absent from the wire. Works for non-`Defaultable` types. Must match the field's type exactly (`Default(Int64(3))` on an `Int64`). |
| `Validate(f, msg=)` | `def(T) -> Bool` run after reading; failure raises `InvalidValue` with `msg` (default "Validation failed"). One of the checks in [Validation](#validation). |
| `Transform(f)` | Reads the wire value as `f`'s argument type and stores `f(value)`. See [Validation](#validation). |
| `SerializeWith(f)` | Writes `f(value)` in place of the field; reading is unchanged. See [Validation](#validation). |

### Validation

Checks are field attributes too. The framework runs a field's checks right
after reading it, in order; the first failure raises `InvalidValue` with the
check's message, and the error path names the field.

```mojo
from emberserde import AnyOf, Enum, Eq, NonEmpty, Not, Range, Size


@fieldwise_init
struct Server(Defaultable, Movable):
    @__annotation(Range(1, 65535, msg="bad port"))
    var port: Int

    @__annotation(NonEmpty(), Size(1, 64))
    var host: String

    @__annotation(Enum["dev", "prod"]())
    var env: String

    @__annotation(AnyOf(Eq(0), Range(10, 20)), Not(Eq(13)))
    var level: Int

    def __init__(out self):
        ...
```

| Check | Passes when | Default message |
|---|---|---|
| `Validate(f)` | `f(value)` is `True` | Validation failed |
| `Range(min, max)` | `min <= value <= max` | Value out of range |
| `Eq(value)` | equal to `value` | Value is not equal |
| `Enum[a, b, ...]()` | equal to one of the listed values | Value not in options |
| `Size(min, max)` | length within bounds (`String` counts bytes) | Value out of size range |
| `NonEmpty()` | length above zero | Value must not be empty |
| `Unique()` | no two elements equal | Values are not unique |
| `Not(check)` | `check` fails | Expected validator to fail |
| `AnyOf(c1, c2, ...)` | at least one check passes | Value not in options |
| `OneOf(c1, c2, ...)` | exactly one check passes | Value must match exactly one option |
| `NoneOf(c1, c2, ...)` | no check passes | Value matched a rejected validator |

- Every check takes an optional trailing `msg`: `Range(1, 65535, msg="bad port")`, `Validate(f, "must be even")`.
- Checks carrying a value (`Validate`, `Range`, `Eq`, `Enum`) must match the field's type exactly, like `Default`: `Range(Int64(0), Int64(10))` on an `Int64`. Bare literals infer `Int`, `Float64` and `String`.
- A value filled in by `Default` (or `T()`) for a missing key is not checked.
- `Unique` compares every pair, so it is O(n²). On untrusted input, bound the length first: `@__annotation(Size(0, 1000), Unique())` (checks run in order).
- Checks run only while deserializing a struct's fields. Serialization ignores them. A check on an `Optional` field fails to compile; write a `Validate` over the `Optional` instead.
- `Enum` is a set-membership check, unrelated to the `Variant` enums below.
- `Validate` moved from `emberserde.field` to `emberserde.validate`; `from emberserde import Validate` is unchanged.

**Your own checks.** Conform to `FieldCheck`:

```mojo
from emberserde import FieldCheck


@fieldwise_init
struct IsEven(FieldCheck):
    def check[T: AnyType](self, value: T) -> Bool:
        comptime assert T == Int, "IsEven needs an Int field"
        return rebind[Int](value) % 2 == 0

    def message(self) -> StaticString:
        return "must be even"
```

**Converting on read.** `Transform(f)` reads the wire value as `f`'s argument
type and stores `f(value)`. It runs on read only: the field is written back as
its own type. If `f` raises, the read fails with `InvalidValue` and the raised
text. A field takes at most one `Transform`, and its checks run on the
converted value.

```mojo
from emberserde import Transform


def parse_level(s: String) raises -> Int:
    if s == "low":
        return 1
    raise Error("unknown level: " + s)


@fieldwise_init
struct Job(Movable):
    @__annotation(Transform(parse_level))
    var level: Int  # wire: {"level": "low"}
```

`clamp[lo, hi]` pairs with `Transform` to pull an out-of-range value into
range instead of rejecting it: `@__annotation(Transform(clamp[0, 100]))`.

**Converting on write.** `SerializeWith(f)` writes `f(value)` in place of the
field; reading is unchanged. If `f` raises, the write fails with
`InvalidValue` and the raised text. A field takes at most one.

```mojo
from emberserde import SerializeWith


def redact(s: String) -> String:
    return "********"


@fieldwise_init
struct Login(Movable):
    var user: String

    @__annotation(SerializeWith(redact))
    var password: String  # read as sent, written as "********"
```

**Rules across fields.** Put a check on the struct itself. It runs once every
field is read and any missing ones are filled, and sees the whole value; the
error path is the struct's own.

```mojo
from emberserde import Validate


@__annotation(
    Validate(
        lambda (d: DateRange) -> Bool: d.start <= d.end, "start must be <= end"
    )
)
@fieldwise_init
struct DateRange(Movable):
    var start: Int
    var end: Int
```

### Struct modifiers

Struct-level settings are annotations too, placed above the struct:

```mojo
from emberserde import DenyUnknownFields, RenameAll


@__annotation(RenameAll(.CamelCase), DenyUnknownFields())
@fieldwise_init
struct Config(Copyable, Defaultable, Movable):
    var api_key: String
    var max_retries: Int

    def __init__(out self):
        ...

# wire: {"apiKey":"k","maxRetries":5}
# {"apiKey":"k","maxRetries":5,"extra":1} -> raises UnknownField
```

A field's own `Rename` wins over `RenameAll`. `RenamePolicy` offers `SnakeCase`, `CamelCase`, `PascalCase`, `KebabCase`,
`ScreamingSnakeCase`, `ScreamingKebabCase`, `LowerCase`, and `UpperCase`.
Declared names are tokenized first, so the policy works whatever convention
the field was written in.

### Enums

Mojo has no native enums; `Variant` fills the role and is externally tagged
on the wire. Put a `Rename` on each arm's struct for a stable tag, otherwise
the tag falls back to the arm's canonical type name (which embeds module paths and
stdlib spellings, so treat that as debug-only).

```mojo
from std.utils import Variant
from emberserde import Rename


@__annotation(Rename("circle"))
@fieldwise_init
struct Circle(Copyable, Movable):
    var radius: Float64


@__annotation(Rename("square"))
@fieldwise_init
struct Square(Copyable, Movable):
    var side: Float64


comptime Shape = Variant[Circle, Square]

# wire: {"circle":{"radius":2.0}}
```

Non-self-describing formats key on the arm *index* instead of the name.

### Missing, unknown, and duplicate fields

On read, the reflection default matches wire fields back onto declared fields
in any order and then applies these rules:

- An `Optional` field absent from the wire becomes `None`.
- A `Skip` or `Default` field absent from the wire takes its default.
- Any other absent field raises `MissingField`.
- An unknown wire field is skipped, unless the struct carries `DenyUnknownFields()`.
- A field appearing twice raises `DuplicateField`.
- Two fields resolving to the same wire name fail the build.

### Errors

Every hook and entry point raises a typed `SerializationError` or
`DeserializationError`, so `except e` hands you the struct directly. Both
carry a `message` and a `kind` to branch on (`TypeMismatch`, `MissingField`,
`UnknownVariant`, ...). A deserialization error also records the wire path to
the failure, built lazily as the error unwinds:

```
at .inner.y: expected a number (TypeMismatch)
```

## Supported types

Round-trip out of the box: `Bool`, `String`, `Int`, `Float64`, and every
other `SIMD` scalar and vector, `Codepoint`, `ComplexSIMD`, `Optional`,
`Variant`, `Tuple`, `List`, `Array`, `Set`, `Dict`, `Deque`, `LinkedList`,
`Counter`, `OwnedPointer`, `ArcPointer`, and any plain struct via reflection.
Recursive types work through `List[Self]`.

Serialize-only, since they are non-owning views: `StringSlice`, `Pointer`,
and `Span`. A `Span[Byte]` routes through the bytes hook; any other `Span`
rides the wire as a sequence.

## Writing a format

A format implements `Serializer` and `Deserializer`. Each declares five
`comptime` state types (`SeqType`, `MapType`, `StructType`, `TupleType`,
`EnumType`) and the primitive hooks:

| Data model | Serializer | Deserializer |
|---|---|---|
| bool | `serialize_bool` | `expect_bool` |
| number | `serialize_number[dt]` | `expect_number[dt]` |
| string | `serialize_string` | `expect_string` |
| bytes | `serialize_bytes` | `expect_bytes` |
| optional | `serialize_none` / `serialize_some` | `expect_optional` |
| seq / map / struct / tuple / enum | `begin_*` returning a state struct | `begin_*` returning a state struct |

`serialize_number` is parameterized on `DType`, so one method covers every
numeric width. The state structs are bound by `SeqSerState`, `MapSerState`,
`StructSerState`, `TupleSerState`, `EnumSerState` and their `*DerState`
counterparts; the framework drives them (`serialize_element`,
`serialize_field`, `expect_field_index`, `end`, ...).

Two methods on the traits are **framework drivers, not hooks**:
`serialize_struct` and `expect_struct` hold the reflection, rename, skip, and
missing-field logic. Overriding them silently opts out of all of it. Implement
`begin_struct` and the struct state type instead.

On the read side the struct state returns field *indices*, not names, from
`expect_field_index`. Two framework helpers do the mapping:

- A self-describing format reads the key off the wire and resolves it with
  `field_index[T](name)`, which applies renames and aliases and returns
  `UNKNOWN_FIELD` when nothing binds.
- An ordered format with no names on the wire steps through
  `next_wire_field[T](start)`, which skips `Skip` fields so values stay
  aligned.

A non-self-describing format must also override `serialize_some` to write a
presence marker, since `Some(v)` and a bare `v` would otherwise be
byte-identical on the wire.

Optional sub-traits:

- `SelfDescribingDeserializer` adds `deserialize_any`, returning a
  format-owned `Value` type for input whose shape is unknown ahead of time.
- `BorrowingDeserializer` adds `raw_bytes[kind]`, handing out the raw wire
  bytes of one value for deferred-parse types.

## Development

```bash
pixi run test            # run all tests
pixi run format          # mojo format -l 80 .
pixi run build           # precompile to emberserde.mojoc
pixi run check_mojo_pins # assert the mojo version specs in pixi.toml agree
pixi run precommit       # format + check_mojo_pins + test
```

Run one test file directly:

```bash
mojo run -D ASSERT=all -I . -I test test/serialize/test_primitives.mojo
```

Tests live under `test/serialize/` and `test/deserialize/`, split by data-model
category rather than by type. Deserialize tests feed hand-written wire
literals so an encode/decode bug that is symmetric cannot round-trip past the
assertion.

## Roadmap

- **IO abstraction.** Only in-memory input is supported today. Streams and
  files follow once Mojo's IO story settles.

## License

Apache 2.0. See [LICENSE](LICENSE).
