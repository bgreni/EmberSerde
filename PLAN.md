# Plan: A serde-like Serialization Framework for Mojo

## Context

You want a general-purpose, format-agnostic serialization framework for Mojo — *inspired by* Rust's serde but designed for Mojo's type system and reflection story — and then to port EmberJson onto it. Today EmberJson's `Serializer` trait, reflection-driven defaults, and `Parser` are tightly coupled to JSON ([emberjson/_serialize/reflection.mojo](emberjson/_serialize/reflection.mojo), [emberjson/_deserialize/reflection.mojo](emberjson/_deserialize/reflection.mojo)). The framework will lift those abstractions into a separate package that any format can plug into, and then EmberJson becomes the first consumer.

This is **not** a faithful port of serde. Serde's design is shaped by Rust constraints (no reflection, no comptime conformance checks, derive macros as the only auto-generation tool) that Mojo doesn't share. We keep serde's good ideas — separation of "data model" from "format" from "type", a single `Deserialize`/`Serialize` interface per type, externally-tagged enums as the default — and discard the parts that exist purely to work around Rust's limitations: the Visitor pattern, per-Rust-shape data-model variants (`UnitStruct`/`NewtypeStruct`/`TupleStruct` and the four `*Variant` siblings), per-format error trait genericity, and the assumption that the macro must hand metadata to the format. Mojo's `reflect[T]` + `comptime if conforms_to` does that work directly.

**Decisions locked in (from clarification):**
- New standalone package (e.g. `mojo-serde`); EmberJson takes it as a dependency.
- **Slim data model (~24 variants)** tailored to Mojo's type system. We drop the Rust-shape-specific variants (`UnitStruct`, `NewtypeStruct`, `TupleStruct`, `UnitVariant`, `NewtypeVariant`, `TupleVariant`, `StructVariant`) — reflection lets the framework detect "zero-field struct", "single-field struct", etc. directly, and Mojo's `Variant[A, B, C]` has only one enum shape (each arm is just a type, dispatched by `isa[T]()`). See Phase 2 for the full list and merge rules.
- v1 has no field-level attributes (`rename`/`skip`/`default`/`flatten`). Types that need custom behavior implement the traits manually. Future reflection (attribute introspection) is the planned mechanism for v2.
- v1 ships with JSON only as the proving format; second format comes after EmberJson is fully ported.
- **No Visitor pattern.** The deserialization side uses direct dispatch (`Deserializer` trait with `expect_*` + framing methods) rather than callback-style visitors. See "Architectural shape" for the reasoning. This removes per-type visitor structs, the `SeqAccess`/`MapAccess`/`EnumAccess` accessor traits, and the comptime-associated-`Value` pattern.
- **`SelfDescribing` sub-trait** carries the `deserialize_any` / `peek_kind` escape hatch needed by dynamic types (JSON `Value`) and by the `Coerce` adapter. Non-self-describing formats implement only `Deserializer`.
- **Permissive parsing is user-space.** `Coerce[Target, func]` — ported from EmberJson's existing [Coerce](emberjson/schema.mojo#L573-L597) — is the opt-in mechanism for "`Int64` accepts `"42"`". The framework's primitives are strict.
- **Two data-model artifacts.** `DataModelKind` is a comptime vocabulary of variant names (used by error messages and `peek_kind`); `Value` is the runtime tagged-union ADT (returned by `deserialize_any` and operated on by `Coerce`). EmberJson's `Value` aliases to `serde.Value`, so `Parser.parse_value` *is* `deserialize_any` for JSON.

**Mojo constraints confirmed in exploration:**
- No parametric traits → format-agnosticism is achieved via generic functions accepting `Some[Serializer]`, not `trait Serializer[W: Writer]`. The comment at [emberjson/_serialize/reflection.mojo:13](emberjson/_serialize/reflection.mojo#L13) confirms this is a known limitation.
- No associated types on traits → use `comptime` members (`comptime Value = ...`) on conforming structs.
- No derive macros → reflection (`reflect[T]()` + `comptime for`) is the only auto-derive mechanism.
- No trait objects → all dispatch is `comptime if conforms_to(T, ...)`. Zero runtime overhead, but the inliner must do real work.
- `where` clauses have bugs in some contexts — fall back to `comptime assert _type_is_eq[T, U]()` (see [emberjson/lazy.mojo:112](emberjson/lazy.mojo#L112)).
- `Parser` and the trait `Deserializer` already exist in EmberJson but the trait is unused — proof that the abstraction was attempted but never wired through. We will replace, not extend.

---

## Architectural shape

The framework is three traits — plus one sub-trait for self-describing formats:

```
Serialize:      a Mojo type knows how to feed itself into a Serializer
Serializer:     a format knows how to consume each data-model variant
Deserialize:    a Mojo type knows how to build itself from a Deserializer
Deserializer:   a format exposes strict primitives + framing for composites
SelfDescribing: a Deserializer that can additionally surface dynamic values
```

Both sides follow the same shape: **the type asks, the format delivers.** Serialization pushes values into `serializer.serialize_*`; deserialization pulls values out via `d.expect_*` / `d.begin_*`. Reflection (`reflect[T]` + `comptime for`) walks struct fields on both sides.

We deliberately do **not** port serde's Visitor pattern. In Rust the Visitor exists because the format has no way to introspect the type it's producing, so the type must hand it a vtable-shaped callback bundle. In Mojo every call site is monomorphic on `T`, so `comptime if conforms_to(T, ...)` and `reflect[T]` give the format direct dispatch — there's no place we'd have a `V: Visitor` that we couldn't equivalently have a `T: Deserialize`. Dropping Visitor removes per-type visitor structs, the `SeqAccess`/`MapAccess`/`EnumAccess` accessor traits, and the comptime-associated-`Value` pattern that would otherwise be the riskiest part of the framework.

Two follow-on consequences:

- **Dynamic types use a narrow escape hatch.** Types like JSON's `Value` that genuinely don't know what shape they want call `d.deserialize_any()` (on `SelfDescribing`) and get back the shared `Value` ADT (Phase 2.2). This is the *only* place a "give me whatever you find" surface exists; the rest of the framework is strict. Non-self-describing formats (bincode) implement `Deserializer` but not `SelfDescribing`, so `Value` and friends fail to compile against them with a clear constraint error — which matches the truth that there's no shape info on the wire to surface.
- **Coercion is a user-space adapter, not a format-side policy.** Permissive parsing (`Int64` accepting `"42"`) lives in `Coerce[Target, func]` — an opt-in field-level wrapper ported from EmberJson's existing [Coerce](emberjson/schema.mojo#L573-L597) that depends only on `SelfDescribing`. Strict by default, permissive where the user writes `Coerce[...]`. This is strictly better than serde's per-visitor permissiveness because (a) it's per-field opt-in rather than implicit, and (b) the same `CoerceInt` works against any self-describing format with no per-format code.

---

## Phase 1 — New package skeleton

### 1.1 Repository setup

Create a new git repo `mojo-serde` (working name; pick the final name before publishing). Mirror EmberJson's structure since it's a known-good pattern.

Files to create:
- `pixi.toml` — same channels (`https://conda.modular.com/max-nightly`, `https://repo.prefix.dev/modular-community`, `conda-forge`), same Mojo pin `mojo >=0.26.2.0.dev2026020205,<0.27`, same platforms (`osx-arm64`, `linux-aarch64`, `linux-64`).
- `pixi.lock` — generated.
- `LICENSE`, `README.md`, `.gitignore` (copy EmberJson's pattern).
- `run_tests.py` — walks `test/serde/` and runs each `.mojo` file with `mojo -D ASSERT=all -I .`. Copy from EmberJson's `run_tests.py` verbatim and change the test directory.
- `serde/__init__.mojo` — empty placeholder for now.

### 1.2 Pixi tasks

In `pixi.toml`, define the same task surface as EmberJson so muscle memory transfers:
- `test` → `python run_tests.py`
- `build` → `mojo package serde -o serde.mojopkg`
- `format` → `mojo format -l 80 .`
- `bench` → reserved; deferred until Phase 5
- `precommit` → `format && test`

### 1.3 Module layout to create as empty stubs

```
serde/
  __init__.mojo          # public API, populated last
  data_model.mojo        # enum of data-model variants
  error.mojo             # SerdeError struct
  ser/
    __init__.mojo
    trait.mojo           # Serialize, Serializer traits + state structs
    impls.mojo           # Serialize impls for stdlib types
    reflection.mojo      # reflection-driven default serialize[T]
  de/
    __init__.mojo
    trait.mojo           # Deserialize, Deserializer, SelfDescribing traits
    impls.mojo           # Deserialize impls for stdlib types
    reflection.mojo      # reflection-driven default deserialize[T]
    coerce.mojo          # Coerce[Target, func] adapter for permissive parsing
```

### 1.4 Exit criteria for Phase 1

- `pixi run format` runs without error on the empty tree.
- `pixi run test` runs and reports "no tests" cleanly.
- The package builds: `pixi run build` produces `serde.mojopkg`.

---

## Phase 2 — Define the data model

The data model has two distinct artifacts:

- **`DataModelKind`** — a comptime vocabulary of variant *names*. No values, just identifiers. Used in error messages, trait documentation, and `peek_kind` on self-describing deserializers (where you want to query the shape without materializing).
- **`Value`** — a runtime tagged-union ADT that actually carries data. One arm per `DataModelKind`. Returned by `deserialize_any` on `SelfDescribing` deserializers and operated on by `Coerce[T, func]`.

They are linked but distinct: `Value.kind() -> DataModelKind` is the bridge. Splitting them lets `peek_kind` be cheap (just look at the next byte / tag) without forcing materialization.

### 2.1 The `DataModelKind` vocabulary

In `serde/data_model.mojo`, define the 24 variant names as comptime strings on a flat namespace struct:

```mojo
struct DataModelKind:
    # Primitives (16)
    comptime Bool       = "bool"
    comptime I8         = "i8"
    comptime I16        = "i16"
    comptime I32        = "i32"
    comptime I64        = "i64"
    comptime I128       = "i128"
    comptime U8         = "u8"
    comptime U16        = "u16"
    comptime U32        = "u32"
    comptime U64        = "u64"
    comptime U128       = "u128"
    comptime F32        = "f32"
    comptime F64        = "f64"
    comptime Char       = "char"
    comptime Str        = "str"
    comptime Bytes      = "bytes"

    # Option (2)
    comptime None       = "none"
    comptime Some       = "some"

    # Unit (1)
    comptime Unit       = "unit"

    # Sequence framing (2)
    comptime Seq        = "seq"        # variable-length
    comptime Tuple      = "tuple"      # fixed-arity

    # Record framing (2)
    comptime Map        = "map"        # arbitrary-keyed
    comptime Struct     = "struct"     # comptime-known string keys

    # Enum (1)
    comptime Enum       = "enum"       # externally-tagged sum, payload follows
```

These are strings (not numbers) so error messages render as `"expected struct, got seq"` without lookup tables, and so `kind: DataModelKind` parameters print readably.

### 2.2 The `Value` ADT

In the same `serde/data_model.mojo`, define the runtime tagged-union form. Each arm corresponds to exactly one `DataModelKind`:

```mojo
struct Value:
    # Backed by a Variant over all 24 leaf types; the helpers below hide the
    # Variant access pattern so callers don't depend on the storage shape.
    var _v: Variant[
        Bool, Int8, Int16, Int32, Int64, Int128,
        UInt8, UInt16, UInt32, UInt64, UInt128,
        Float32, Float64, Char, String, List[Byte],
        _NoneTag, _SomeBox,    # Option arms; _SomeBox holds a boxed Value
        _UnitTag,
        List[Value],            # Seq
        _TupleBox,              # Tuple — fixed-arity Value list
        Dict[Value, Value],     # Map
        _StructBox,             # Struct — name + ordered (name, Value) pairs
        _EnumBox,               # Enum — name + variant + boxed Value payload
    ]

    fn kind(self) -> DataModelKind: ...

    # Cheap predicate accessors
    fn is_i64(self) -> Bool: ...
    fn is_str(self) -> Bool: ...
    fn is_struct(self) -> Bool: ...
    # ... one per arm

    # Extractors — raise on kind mismatch
    fn as_i64(self) raises -> Int64: ...
    fn as_str(self) raises -> StringSlice[__origin_of(self)]: ...
    # ... one per arm
```

This is structurally what EmberJson's existing [Value](emberjson/value.mojo) is — a `Variant` over the leaf types plus accessor/predicate methods. The Phase 6.4 port aliases EmberJson's `Value` to this type so JSON-side code keeps the same surface and `Parser.parse_value` becomes the literal implementation of `deserialize_any`.

The boxed helper structs (`_SomeBox`, `_TupleBox`, `_StructBox`, `_EnumBox`) exist because `Variant` doesn't permit recursive arms directly; the box owns an `OwnedPointer[Value]` (or `List[Value]` for tuples/structs/enums). Keep them private to the module — the public API is `Value.kind()` + the predicates/extractors.

### 2.3 What we dropped versus serde and why

Serde's full data model has 29 variants. We drop seven that are Rust-syntax-shaped and reflection can subsume:

| Serde variant | Why dropped | What replaces it |
| --- | --- | --- |
| `UnitStruct` | A Rust struct with zero fields. Reflection sees `field_count() == 0`. | `Struct` with len 0. Format emits the zero-field encoding. |
| `NewtypeStruct` | A Rust struct with one positional field, serialized transparently. Reflection sees `field_count() == 1`. | `Struct` with len 1, or transparent emission via future v2 attribute. |
| `TupleStruct` | A Rust struct with positional fields. Mojo struct fields always have names — no syntactic distinction exists. | `Struct` (with synthetic numeric names if needed) or `Tuple` for the explicit fixed-arity case. |
| `UnitVariant` | An enum arm with no payload. In Mojo, `Variant[A, B, C]` arms are *types*; "no payload" means the active type is `Unit` (or an empty struct). | `Enum` with `Unit` payload. |
| `NewtypeVariant` | An enum arm wrapping a single value. In Mojo, that's just `Variant[A, B, C]` where the active type is the wrapped value. | `Enum` with that value as payload — recursion handles the shape. |
| `TupleVariant` | An enum arm wrapping a tuple. | `Enum` with `Tuple` payload. |
| `StructVariant` | An enum arm wrapping a struct. | `Enum` with `Struct` payload. |

The general principle: **Rust's data model encodes syntactic shape; Mojo's encodes semantic shape.** Whether a struct is "newtype" or "regular" or "tuple" is a *macro-time* distinction in Rust, baked into the variant set because the macro is the only thing that can introspect it. In Mojo, `reflect[T]` sees field count and naming directly at every call site — the framework reads it, decides how to encode, and the format never needs a separate variant to know "this came from a 1-field struct."

Same with enums: `Variant[A, B, C]` has exactly one shape (a tagged union over types), so one `Enum` variant in the data model suffices. The four `*Variant` arms in serde exist purely because Rust enums have four syntactic forms, each requiring a different macro expansion. Mojo doesn't have that surface — and won't, even if `enum` lands as a language feature, because Mojo enums (whenever they arrive) will most likely be type-tagged unions much like `Variant`.

Cross-language fidelity (a Rust program's JSON output round-tripping through Mojo) is preserved at the *wire level*, not the data-model level: `null` is `null` regardless of which Rust variant emitted it, and the receiver maps it back to `Unit` or `None` based on the target type. We never need to distinguish "this `null` came from `UnitStruct` versus `Unit`" — nothing on the wire encodes that, and nothing in Mojo's type system can consume the distinction.

### 2.4 Error type

In `serde/error.mojo`:

```mojo
struct SerdeError(Writable):
    var kind: SerdeErrorKind
    var message: String
    var path: Optional[String]  # JSON-pointer-style path for nested errors
```

`SerdeErrorKind` is a small enum: `UnexpectedVariant`, `MissingField`, `DuplicateField`, `UnknownField`, `InvalidValue`, `Custom`. These are raised through `raises`; Mojo doesn't have typed errors, so the `kind` field is the typed dispatch.

### 2.5 Exit criteria for Phase 2

- `data_model.mojo` (with both `DataModelKind` and `Value`) and `error.mojo` compile.
- Unit test: construct a `Value` of each kind, verify `Value.kind()` returns the expected `DataModelKind`, round-trip through the predicate/extractor accessors.
- Unit test: construct a `SerdeError`, write it through a `String`, assert the rendering format.

---

## Phase 3 — Serialization side

### 3.1 The `Serializer` trait

In `serde/ser/trait.mojo`. One method per data-model variant from Phase 2.1. The compound variants (seq/map/struct/tuple/enum) return state structs that the caller drives — this is the Mojo replacement for serde's `SerializeSeq`/`SerializeMap`/`SerializeStructVariant` associated types, which Mojo can't express on a trait.

```mojo
trait Serializer:
    # State types are comptime members (Mojo's stand-in for associated types)
    comptime SeqState:    AnyType
    comptime MapState:    AnyType
    comptime StructState: AnyType
    comptime TupleState:  AnyType
    comptime EnumState:   AnyType

    def serialize_bool(mut self, v: Bool) raises
    def serialize_i64(mut self, v: Int64) raises
    def serialize_u64(mut self, v: UInt64) raises
    def serialize_f64(mut self, v: Float64) raises
    def serialize_str(mut self, v: StringSlice) raises
    def serialize_bytes(mut self, v: Span[Byte]) raises
    def serialize_none(mut self) raises
    def serialize_some[T: Serialize](mut self, v: T) raises
    def serialize_unit(mut self) raises

    def begin_seq(mut self, len: Optional[Int]) raises -> Self.SeqState
    def begin_tuple(mut self, len: Int) raises -> Self.TupleState
    def begin_map(mut self, len: Optional[Int]) raises -> Self.MapState
    def begin_struct(mut self, name: StaticString, len: Int) raises -> Self.StructState
    def begin_enum(
        mut self, name: StaticString, idx: UInt32, variant: StaticString
    ) raises -> Self.EnumState
```

No `serialize_unit_struct` / `serialize_newtype_struct` / `serialize_*_variant`. A zero-field struct is `begin_struct(name, 0); st.end()`. A one-field struct is `begin_struct(name, 1); st.serialize_field("0", v); st.end()` (or whatever name reflection produced). All enum arms — unit-payload, single-payload, tuple-payload, struct-payload — go through `begin_enum` followed by a single recursive serialization of the payload through normal dispatch. The format does not need separate methods because the payload's shape is determined by the payload's *type*, which reflection sees directly.

The `SeqState`, `MapState`, `StructState`, `TupleState`, `EnumState` are types each format defines. Their required methods:

```mojo
# SeqState
def serialize_element[T: Serialize](mut self, v: T) raises
def end(deinit self) raises

# MapState
def serialize_key[K: Serialize](mut self, k: K) raises
def serialize_value[V: Serialize](mut self, v: V) raises
def end(deinit self) raises

# StructState
def serialize_field[T: Serialize](mut self, name: StaticString, v: T) raises
def skip_field(mut self, name: StaticString) raises
def end(deinit self) raises

# TupleState — same as SeqState but with fixed-length semantics

# EnumState
def serialize_payload[T: Serialize](mut self, v: T) raises   # called exactly once
def end(deinit self) raises
```

For externally-tagged JSON, `begin_enum("Variant", 0, "Foo")` writes `{"Foo":`, `serialize_payload(v)` recurses, and `end()` writes `}`. The payload can be any shape — unit (`null`), primitive, struct (`{...}`), tuple (`[...]`) — and the format doesn't branch on which: it just serializes whatever it gets.

### 3.2 The `Serialize` trait

```mojo
trait Serialize:
    def serialize[S: Serializer](self, mut serializer: S) raises
```

### 3.3 Reflection-driven default

In `serde/ser/reflection.mojo`. This is the entry point users call:

```mojo
def serialize[T: AnyType, //, S: Serializer](value: T, mut s: S) raises:
    comptime if conforms_to(T, Serialize):
        value.serialize(s)
    else:
        _default_serialize(value, s)

def _default_serialize[T: AnyType, //, S: Serializer](value: T, mut s: S) raises:
    comptime r = reflect[T]()
    comptime assert r.is_struct(), "cannot serialize non-struct type"
    var st = s.begin_struct(name_of[T](), r.field_count())
    comptime for i in range(r.field_count()):
        st.serialize_field(r.field_names()[i], r.field_ref[i](value))
    st.end()
```

The pattern is already proven in EmberJson at [emberjson/_serialize/reflection.mojo:203-228](emberjson/_serialize/reflection.mojo#L203-L228); we're generalizing it from "begin_object/write_key" to "begin_struct/serialize_field".

### 3.4 Stdlib `Serialize` impls

In `serde/ser/impls.mojo`, provide impls for the types every user needs. Without these, every program would need to re-implement the obvious cases.

| Type | Strategy |
|---|---|
| `Bool` | `serializer.serialize_bool(self)` |
| `Int8`..`Int64`, `UInt8`..`UInt64` | `serialize_iN` / `serialize_uN` |
| `Int` (machine-sized) | dispatch by size to `serialize_i64` |
| `Float32`, `Float64` | `serialize_fN` |
| `String`, `StringSlice`, `StaticString` | `serialize_str` |
| `Bytes`, `Span[Byte]` | `serialize_bytes` |
| `Optional[T]` | `serialize_none` if empty, else `serialize_some(value)` |
| `List[T]` | `begin_seq(Some(len))` → loop → `end()` |
| `Dict[K, V]` | `begin_map(Some(len))` → loop → `end()` |
| `Tuple[T1, ...]` | `begin_tuple(N)` → `@parameter for` → `end()` |
| `Variant[T1, ...]` | externally tagged: `begin_enum(...)` → recursive `serialize_payload(active_arm)` → `end()` |
| `InlineArray[T, N]` | `begin_tuple(N)` → loop → `end()` |

`Variant` is the tricky one. Serde's default for Rust enums is externally tagged: `{"Variant": payload}`. We do the same — find the active arm via `isa[T]()`, call `begin_enum(name_of[Self](), idx, name_of[T]())`, then `serialize_payload(active_value)` which recursively dispatches through the framework. The payload's encoding (unit/primitive/struct/tuple) falls out of normal serialization of the active arm's type — no per-shape methods needed on `Serializer`.

### 3.5 Exit criteria for Phase 3

- All trait + state types compile.
- Stdlib `Serialize` impls compile.
- Reflection default serializes a nested struct end-to-end (verified in Phase 5 with the debug format).

---

## Phase 4 — Deserialization side

Mojo's reflection + comptime story lets us simplify significantly versus serde here. We do **not** port the Visitor pattern (see "Architectural shape" above for the reasoning). What remains is two traits — `Deserializer` (primitives + framing) and `Deserialize` (one method per type) — plus a `SelfDescribing` sub-trait that surfaces the dynamic-value escape hatch needed for types like JSON's `Value` and for the permissive-parsing `Coerce` adapter.

### 4.1 The `Deserializer` trait

In `serde/de/trait.mojo`. Primitives are strict ("give me a bool, error if you can't"); framing methods carve up composite shapes. No callbacks, no visitor argument.

```mojo
trait Deserializer:
    # Strict primitives — caller knows the data-model variant it wants
    def expect_bool(mut self) raises -> Bool
    def expect_i64(mut self) raises -> Int64
    def expect_u64(mut self) raises -> UInt64
    def expect_f64(mut self) raises -> Float64
    def expect_str(mut self, out s: String) raises
    def expect_bytes(mut self, out b: List[Byte]) raises
    def expect_unit(mut self) raises

    # Option framing
    def expect_none(mut self) raises -> Bool   # true if next is null/none and consumed

    # Sequence framing
    def begin_seq(mut self) raises -> Optional[Int]    # len if known up front
    def next_element(mut self) raises -> Bool          # true if another element follows
    def end_seq(mut self) raises

    # Map framing
    def begin_map(mut self) raises -> Optional[Int]
    def next_entry(mut self) raises -> Bool
    def end_map(mut self) raises

    # Tuple framing — fixed arity
    def begin_tuple(mut self, len: Int) raises
    def end_tuple(mut self) raises

    # Struct framing — the deserializer reads reflect[T] itself; the type doesn't pass field names
    def begin_struct[T: AnyType](mut self) raises
    def next_field_name(mut self) raises -> Optional[String]   # None when struct ends
    def deserialize_field_value[F: Deserialize](mut self, out f: F) raises
    def skip_value(mut self) raises                            # for unknown fields
    def end_struct(mut self) raises

    # Enum framing — externally tagged by default
    def begin_enum[T: AnyType](mut self) raises -> (UInt32, String)   # (idx, variant name)
    def end_enum(mut self) raises
```

A note on `begin_struct[T]`: the deserializer takes `T` as a comptime parameter so it can call `reflect[T].field_names()` itself. For self-describing formats (JSON) that means "read `{`, prepare for keyed lookup against this name list"; for non-self-describing formats (bincode) it means "remember the expected field order so `next_field_name` can return names from `reflect[T]` rather than reading them off the wire." Both styles hide behind the same surface, and the *type* never has to pass field metadata in — reflection is the source of truth.

### 4.2 The `SelfDescribing` sub-trait

Some types — JSON's `Value`, the `Coerce[Target, func]` adapter (4.6) — need to receive *whatever* shape the format produced and react. That only makes sense for formats that carry shape info on the wire. Express it as a sub-trait so the constraint is checked at compile time:

```mojo
trait SelfDescribing(Deserializer):
    def peek_kind(mut self) raises -> DataModelKind
    def deserialize_any(mut self) raises -> Value
```

`peek_kind` returns the cheap vocabulary tag from `DataModelKind` (Phase 2.1) so callers can branch on shape without paying for materialization. `deserialize_any` returns the runtime tagged-union `Value` (Phase 2.2). EmberJson's existing [Value](emberjson/value.mojo) is structurally identical to `serde.Value`; the port aliases them so [Parser.parse_value](emberjson/_deserialize/parser.mojo#L327) becomes the implementation of `deserialize_any` directly — no new code, just a different entry point name.

Non-self-describing formats (bincode, postcard) implement only `Deserializer`. Trying to deserialize a `Value` from bincode fails at compile time with a clear "expected `D: SelfDescribing`" message rather than at runtime with `"deserialize_any not supported"` — which matches the truth (bincode has no shape info to surface) and gives users the failure earlier.

### 4.3 The `Deserialize` trait

```mojo
trait Deserialize:
    @staticmethod
    def deserialize[D: Deserializer](mut d: D, out s: Self) raises
```

One method, mirroring EmberJson's existing `from_json` shape ([emberjson/_deserialize/reflection.mojo:37-46](emberjson/_deserialize/reflection.mojo#L37-L46)) but parameterized on a format-agnostic deserializer. No `Visitor` argument. No associated `Value` type. The body asks the deserializer for what it wants, period.

### 4.4 Reflection-driven default for structs

In `serde/de/reflection.mojo`. This is the analog of EmberJson's [_default_deserialize](emberjson/_deserialize/reflection.mojo#L104-L181) — same loop, generalized over any `Deserializer`:

```mojo
def deserialize[T: AnyType, //, D: Deserializer](mut d: D, out s: T) raises:
    comptime if conforms_to(T, Deserialize):
        T.deserialize(d, s)
    else:
        _default_deserialize(d, s)

def _default_deserialize[T: AnyType, //, D: Deserializer](mut d: D, out s: T) raises:
    comptime r = reflect[T]
    comptime assert r.is_struct(), "cannot deserialize non-struct type"

    comptime if conforms_to(T, Defaultable):
        s = T()
    else:
        # carry over the EmberJson escape hatch verbatim
        comptime assert __all_dtors_are_trivial[T](),
            "cannot deserialize non-Defaultable struct containing fields with non-trivial destructors"
        __mlir_op.`lit.ownership.mark_initialized`(__get_mvalue_as_litref(s))

    d.begin_struct[T]()
    var seen = materialize[InlineArray[Bool, r.field_count()](fill=False)]()

    while True:
        var name_opt = d.next_field_name()
        if not name_opt:
            break
        var name = name_opt.value()

        var matched = False
        comptime for i in range(r.field_count()):
            comptime field_name = r.field_names()[i]
            if name == field_name:
                if seen.unsafe_get(i):
                    raise Error("duplicate field: ", field_name)
                seen[i] = True
                matched = True
                ref f = trait_downcast[_Base](r.field_ref[i](s))
                d.deserialize_field_value(f)

        if not matched:
            d.skip_value()

    # missing-field check with Optional/Default fallback (EmberJson parity)
    comptime for i in range(r.field_count()):
        if not seen.unsafe_get(i):
            comptime if __is_optional[r.field_types()[i]]() or __is_default[r.field_types()[i]]():
                ref f = trait_downcast[_Base & Defaultable](r.field_ref[i](s))
                f = type_of(f)()
            else:
                raise Error("missing field: ", r.field_names()[i])

    d.end_struct()
```

This is the EmberJson body almost line-for-line ([emberjson/_deserialize/reflection.mojo:137-181](emberjson/_deserialize/reflection.mojo#L137-L181)) — just routed through `Deserializer` instead of calling `Parser` directly. No `_StructVisitor[T]` codegen. No accessor traits. The deserializer decides how to drive `next_field_name` (key lookup for JSON, ordered iteration over `reflect[T]` for bincode).

### 4.5 Stdlib `Deserialize` impls

In `serde/de/impls.mojo`. One impl per type, each a one-liner — same shape as EmberJson's existing [__extension blocks](emberjson/_deserialize/reflection.mojo#L200-L466) with `Parser` swapped for a generic `D: Deserializer`:

| Type | Body |
|---|---|
| `Bool` | `s = d.expect_bool()` |
| `Int8`..`Int64` | `s = Int*(d.expect_i64())` (range-check inside the format) |
| `UInt8`..`UInt64` | `s = UInt*(d.expect_u64())` |
| `Float32`, `Float64` | `s = Float*(d.expect_f64())` |
| `String` | `d.expect_str(s)` |
| `Bytes` / `List[Byte]` | `d.expect_bytes(s)` |
| `Optional[T]` | `if d.expect_none(): s = None else: s = T.deserialize(d)` |
| `List[T]` | `d.begin_seq(); while d.next_element(): s.append(deserialize[T](d)); d.end_seq()` |
| `Dict[K, V]` | `d.begin_map(); while d.next_entry(): { k = deserialize[K](d); v = deserialize[V](d); s[k^] = v^ }; d.end_map()` |
| `Tuple[T1, ...]` | `d.begin_tuple(N); comptime for i: s[i] = deserialize[Ti](d); d.end_tuple()` |
| `InlineArray[T, N]` | analogous to `Tuple` |
| `Set[T]` | analogous to `List[T]` with `.add` |
| `Variant[T1, ...]` | externally tagged: `(idx, name) = d.begin_enum[Self](); switch idx { ... }; d.end_enum()` |
| `Value` (shared dynamic ADT) | constrained on `D: SelfDescribing`: `s = d.deserialize_any()` |

No `BoolVisitor`, no `SeqVisitor[T]`, no `MapVisitor[K, V]` — every impl is the body that would have lived inside the corresponding visitor's `visit_*` method, called directly.

### 4.6 The `Coerce[Target, func]` adapter

Permissive parsing ("`Int64` accepts `"42"`") is **not** baked into the framework. Instead, lift EmberJson's existing [Coerce](emberjson/schema.mojo#L573-L597) pattern into `serde/de/coerce.mojo`:

```mojo
@fieldwise_init
struct Coerce[Target: Deserialize, func: def(Value) raises -> Target](Deserialize):
    var value: Self.Target

    @staticmethod
    def deserialize[D: SelfDescribing](mut d: D, out s: Self) raises:
        s = {Self.func(d.deserialize_any())}

    def __getitem__(self) -> ref [self.value] Self.Target:
        return self.value
```

Ship `CoerceInt`, `CoerceUInt`, `CoerceFloat`, `CoerceString` with bodies ported from EmberJson's [`__try_coerce_*` family](emberjson/schema.mojo#L600-L647). Since `serde.Value` aliases EmberJson's `Value`, the variant predicates (`is_int`, `is_str`, …) translate one-to-one.

This factoring beats serde's per-visitor permissiveness in two ways:

1. **Opt-in at the field level.** `Coerce[Int64, ...]` only kicks in where the user writes it. Strict-by-default, permissive-on-request.
2. **Format-portable for free.** `Coerce` only depends on `SelfDescribing`; the same `CoerceInt` works against JSON, msgpack, CBOR with no per-format code.

The cost: `Coerce` requires a `SelfDescribing` deserializer, so a `Coerce[Int64, ...]` field can't be deserialized from bincode. The compile error makes that explicit — which is correct, since coercion-from-string can't work when the format never produces strings where it expected ints.

### 4.7 Exit criteria for Phase 4

- `Deserializer`, `SelfDescribing`, `Deserialize` traits compile.
- Stdlib `Deserialize` impls compile.
- `Coerce` adapter compiles and round-trips through a hand-rolled `SelfDescribing` test deserializer.
- Roundtrip test (Phase 5) passes.

---

## Phase 5 — Test harness and a debug-format reference

### 5.1 Why a debug format

Before porting EmberJson, build a **debug format** in the framework's test directory that emits Rust-`Debug`-style output: `Foo { x: 1, y: "hi", z: [1, 2, 3] }`. This is non-shipping, ~200 lines, and is the only format the framework owns. Its purpose is to:

1. Exercise every method on `Serializer` / `Deserializer` (deserialization is omitted — debug is output-only).
2. Force you to discover trait design flaws *before* you put EmberJson at stake.
3. Provide golden-string tests independent of any real format.

If you can't write the debug format cleanly, the traits are wrong; fix the trait, not the format.

### 5.2 Tests to write

In `test/serde/`:

- `test_primitives.mojo` — serialize each primitive, assert debug-format string.
- `test_seq.mojo` — `List[Int]`, nested `List[List[Int]]`, empty list.
- `test_map.mojo` — `Dict[String, Int]`, iteration order assertions.
- `test_option.mojo` — `Optional[Int]` both arms.
- `test_struct_reflection.mojo` — a 3-field struct, verify field names and values appear.
- `test_nested_struct.mojo` — struct containing struct, list-of-struct, dict-of-struct.
- `test_variant.mojo` — `Variant[Int, String, MyStruct]`, externally-tagged.
- `test_custom_impl.mojo` — user-defined `Serialize` overriding the reflection default.
- `test_deserialize_primitives.mojo` — read primitives from a hand-rolled "list of tokens" deserializer.
- `test_deserialize_struct.mojo` — same for structs.
- `test_deserialize_errors.mojo` — missing field, duplicate field, type mismatch, unknown field.

### 5.3 Test infrastructure

Adopt EmberJson's `run_tests.py` verbatim. Each test file is its own `mojo` invocation with `-D ASSERT=all`.

### 5.4 Exit criteria for Phase 5

- All tests in `test/serde/` pass.
- `pixi run precommit` is green (format + test).
- The framework can serialize a real, nested user struct through the debug format and round-trip it via the token deserializer.

---

## Phase 6 — Port EmberJson onto the framework

This phase is the proof. If the framework is right, this is mostly mechanical rewrites; if it isn't, it'll surface here.

### 6.1 Add the dependency

In EmberJson's `pixi.toml`, add `mojo-serde` as a path-dependency (during development) or registered package (once published). Update `pixi.lock`.

### 6.2 Rewrite the serialization layer

Critical file: [emberjson/_serialize/reflection.mojo](emberjson/_serialize/reflection.mojo).

Today this file contains:
- The old JSON-specific `Serializer` trait (lines 15-40).
- `String`-as-Serializer impl (lines 43-68).
- `_WriteBufferStack` (lines 71-96).
- `PrettySerializer` (lines 99-164).
- The `JsonSerializable` trait (lines 167-173).
- The reflection-driven `serialize[T]` entry points (lines 176-228).

New layout:
- Delete the old `Serializer` trait — it's replaced by `serde.Serializer`.
- Create a new `JsonSerializer` struct (in `emberjson/_serialize/json_serializer.mojo`) that implements `serde.Serializer`. Internally it owns a `_WriteBufferStack` for the buffering.
  - `serialize_str` → escape and emit quoted string (reuse `write_escaped_string` from [emberjson/value.mojo:376-394](emberjson/value.mojo#L376-L394)).
  - `serialize_f64` → reuse the Teju Jagua float writer in [emberjson/teju/](emberjson/teju/).
  - `begin_object`/`begin_struct` → emit `{`, return a `StructState` that tracks "first field?" for comma placement.
  - `begin_seq` → emit `[`, return a `SeqState` that tracks first-element.
- `_WriteBufferStack` stays where it is; it's a buffering implementation detail.
- `PrettySerializer` is rewritten as `PrettyJsonSerializer` — same wrapper idea, but it wraps a `JsonSerializer` and intercepts the `begin_*`/`end_*` / `serialize_field` calls to inject indentation and newlines.
- `JsonSerializable` becomes a deprecated alias for `serde.Serialize`:

```mojo
@deprecated("use serde.Serialize")
comptime JsonSerializable = serde.Serialize
```

- The public `serialize[T]` and `to_string[T]` entry points in [emberjson/__init__.mojo](emberjson/__init__.mojo) keep their signatures; their bodies construct a `JsonSerializer` and delegate to `serde.serialize`.

### 6.3 Rewrite the deserialization layer

Critical file: [emberjson/_deserialize/reflection.mojo](emberjson/_deserialize/reflection.mojo).

Today this file contains:
- An unused `Deserializer` trait (lines 23-34).
- The `JsonDeserializable` trait (lines 37-46).
- The reflection-driven `deserialize[T]` entry points (lines 65-81).
- `_default_deserialize` (lines 104-181).
- `_deserialize_impl` (lines 184-192).

New layout:
- Delete the old `Deserializer` trait — replaced by `serde.Deserializer`.
- Create `JsonDeserializer` struct (in `emberjson/_deserialize/json_deserializer.mojo`) that wraps `Parser` ([emberjson/_deserialize/parser.mojo](emberjson/_deserialize/parser.mojo)) and implements both `serde.Deserializer` and `serde.SelfDescribing`.
  - `expect_bool` / `expect_i64` / `expect_str` / etc. delegate to existing `Parser` methods (`expect_bool`, `expect_int`, `read_string`, …) — these already exist in [Parser](emberjson/_deserialize/parser.mojo).
  - `begin_seq` reads `[` and tracks first-element state; `next_element` peeks for `]` vs `,`; `end_seq` consumes `]`. Same shape as the `List.from_json` body today ([emberjson/_deserialize/reflection.mojo:355-372](emberjson/_deserialize/reflection.mojo#L355-L372)), just unwrapped from a single method into framing calls.
  - `begin_map` / `next_entry` / `end_map` analogously, mirroring [Dict.from_json](emberjson/_deserialize/reflection.mojo#L375-L400).
  - `begin_struct[T]` reads `{` and initializes the key-lookup state; `next_field_name` reads the next quoted key (or returns `None` on `}`); `deserialize_field_value[F]` recurses; `skip_value` consumes one JSON value without binding it.
  - `deserialize_any` is `Parser.parse_value` ([emberjson/_deserialize/parser.mojo:327](emberjson/_deserialize/parser.mojo#L327)) returning a `serde.Value`. Since EmberJson's `Value` is aliased to `serde.Value` (Phase 6.4), this is a literal one-line delegation.
  - `peek_kind` looks at the next non-whitespace byte and returns the corresponding `DataModelKind` without consuming — `{` → `Struct`/`Map`, `[` → `Seq`/`Tuple`, `"` → `Str`, digit/`-` → numeric, `t`/`f` → `Bool`, `n` → `None`/`Unit`.
- The framework's reflection-driven default (Phase 4.4) handles all reflected structs — no `_default_deserialize` body needs to live in EmberJson anymore. Delete it.
- `JsonDeserializable` becomes a deprecated alias for `serde.Deserialize`.
- The public `deserialize[T]` / `try_deserialize[T]` / `parse` entry points keep their signatures; bodies construct a `JsonDeserializer` and delegate.

### 6.4 `Value` type adjustments

In [emberjson/value.mojo](emberjson/value.mojo):

- `Value` implements `serde.Serialize` directly. Its `serialize[S]` method switches on the active variant (using `isa[T]()` checks already in the file) and calls the corresponding `serializer.serialize_*`. For `Object` and `Array`, it opens a struct/seq state and recurses.
- `Value` implements `serde.Deserialize` constrained on `D: SelfDescribing`. Its body is one line: `s = d.deserialize_any()`. No `ValueVisitor` — the deserializer returns a `serde.Value` directly.
- **Decision to lock in**: alias EmberJson's `Value = serde.Value`. They are structurally identical (both `Variant`-backed tagged unions over the data-model leaves), so JSON's existing `parse_value` *is* the implementation of `deserialize_any` and round-tripping through any self-describing format requires zero conversion code.
- The existing `JsonValue` combined trait ([emberjson/traits.mojo](emberjson/traits.mojo)) drops `JsonSerializable`/`JsonDeserializable` and gains `serde.Serialize`/`serde.Deserialize`.

### 6.5 PrettyPrintable stays in EmberJson

The `PrettyPrintable` trait is JSON-specific (knows about indentation rules for nested objects/arrays). It does not move to the framework. The `PrettyJsonSerializer` wraps the framework's `serde.Serializer` interface but is itself JSON-only.

### 6.6 Compatibility window

Keep the deprecated `JsonSerializable` and `JsonDeserializable` aliases for one minor release. Add `@deprecated` notes pointing to `serde.Serialize` / `serde.Deserialize`. Document the migration in the EmberJson changelog with a 5-line example.

### 6.7 Steps in order (so the tree never breaks)

1. Add `mojo-serde` as a dependency. Confirm `pixi run build` still works on EmberJson untouched.
2. Add `JsonSerializer` and `JsonDeserializer` *alongside* the existing code. Don't delete anything yet. Add a single new test that round-trips through them.
3. Switch `Value`'s serialization path to use `JsonSerializer`. Run the full suite — confirm parity.
4. Switch the public `serialize` / `to_string` entry points to delegate. Run the full suite.
5. Switch deserialization analogously: `JsonDeserializer` exists in parallel, then `Value` deserialization routes through it, then public `parse` / `deserialize` delegate.
6. Once the suite is fully on the new path, delete the old `Serializer`/`Deserializer` traits and `_default_serialize` / `_default_deserialize`. Verify nothing imports them.
7. Add deprecation aliases.

This staged rollout means every commit leaves the repo green.

### 6.8 Exit criteria for Phase 6

- `pixi run test` — full existing suite passes unchanged. Tests do not need rewrites; only internal plumbing changes.
- `pixi run fuzz` — fuzzer finds no new crashes.
- `pixi run python_compat` — Python interop works.
- The grep `grep -r "JsonSerializer\|JsonDeserializer" emberjson/` shows the new types are the only ones in use internally; `JsonSerializable`/`JsonDeserializable` only appear as deprecated aliases.

---

## Phase 7 — Performance validation

### 7.1 Baseline

Before merging any framework changes into EmberJson's main branch, capture a baseline:

```
pixi run bench > bench_baseline.txt
```

Commit this to a branch (don't replace `bench_result.txt`).

### 7.2 After the port

```
pixi run bench_compare
```

This compares against the committed `bench_result.txt`. **Required outcome: no regression > 5%** on any existing benchmark.

### 7.3 If there is regression

The framework is `comptime`-resolved and the deserialization path is direct dispatch — no visitor indirection to flatten. The deserialization hot loop should be identical to today's `_default_deserialize` after monomorphization, just with `Parser` method calls replaced by trait calls into `JsonDeserializer` (which forwards to the same `Parser` methods). If profiling shows regression:

1. Profile with the existing bench harness; identify the hot frame.
2. Add `@always_inline` to the framework's `serialize` / `deserialize` entry points, to `_default_deserialize`'s field-dispatch loop, and to `JsonDeserializer`'s framing methods so the trait call collapses into the parser call.
3. Confirm the `Serializer` state structs (`StructState`, `SeqState`) get stack-allocated and aren't heap-boxing.
4. Last resort: specialize the JSON path with a `comptime if T_is_json_value` fast track that skips the framework and goes straight to the JSON parser methods. This is escape-hatch territory; only do it if profiling confirms a real cost.

### 7.4 Exit criteria for Phase 7

- All EmberJson benchmarks within 5% of pre-port baseline.
- New `bench_result.txt` committed (only if regression is < 5% across the board).

---

## Verification

For the framework (`mojo-serde`):
1. `pixi run test` — round-trip tests against the debug format.
2. Manual smoke: serialize a nested struct with `Optional`, `List`, `Variant`, `Dict` fields, confirm output is structurally correct.
3. Cross-check: take a small Rust serde JSON output, feed it through the JSON deserializer (Phase 6) into a Mojo struct, confirm fields match. (Sanity check for data-model parity.)

For the EmberJson port:
1. `pixi run test` — full existing suite passes unchanged.
2. `pixi run fuzz` — fuzzer still finds no crashes.
3. `pixi run bench_compare` — within 5% of baseline.
4. `pixi run python_compat` — Python interop still works.
5. Manual: deserialize a known fixture into a user struct, mutate, re-serialize, diff against expected output.
6. Manual: write a 20-line user struct with `Optional`, `List`, `Variant` fields; round-trip it through `to_string` / `parse`; confirm equality.

---

## Hard parts to flag up front

These are the design risks. Validate each one *before* committing to the architecture by writing a minimal proof in `serde/` that demonstrates it compiles and runs.

### 1. Trait sub-classing for `SelfDescribing`

`trait SelfDescribing(Deserializer)` assumes Mojo supports trait inheritance with the constraint propagating through generic bounds (`D: SelfDescribing` should imply `D: Deserializer`). **Validate before Phase 4**: write a 20-line proof with a base trait, a sub-trait, and a generic function constrained on the sub-trait that calls methods from both. If it doesn't compile, the fallback is to inline `deserialize_any` / `peek_kind` directly onto `Deserializer` and have non-self-describing formats raise from them at runtime (serde-style). That loses the compile-time honesty but keeps the rest of the design intact.

### 2. Method-level type parameters on traits

`Deserializer.deserialize_field_value[F: Deserialize]` and `Deserializer.begin_struct[T]` introduce fresh type parameters at the call site. **Validate before Phase 4**: confirm Mojo allows trait methods to declare their own comptime parameters. EmberJson already does this informally via the `_Base` constraint pattern, but verify it works inside a `trait` declaration. If not, the workaround is to make the deserializer parametric over the target type at construction — less ergonomic but tractable for a single-format-at-a-time use case.

### 3. Shared `Value` ADT vs format-specific dynamic type

`SelfDescribing.deserialize_any` returns a single shared `Value` ADT (Phase 2.2). The alternative — make the return type a comptime associated type per format — reintroduces exactly the comptime-associated-type problem we dropped Visitor to avoid. The plan picks the shared ADT. The implication: every self-describing format pays for `Value`'s representation even if its native dynamic type is shaped slightly differently. Mitigation: make JSON's `Value` *literally* an alias for `serde.Value` so there's zero conversion cost on the format we care most about (Phase 6.4 calls this out). Other formats can convert in their `deserialize_any` body — cost amortized only when dynamic values are actually requested. A separate concern is the `Variant`-of-24-arms backing store for `Value`: validate that Mojo can materialize that without exceeding parameter-pack limits before Phase 2 ships.

### 4. Error type unification

Serde uses a generic `Error` trait per format. Mojo's `raises` carries no payload — all errors are flattened to a string. The plan picks one `SerdeError` struct and standardizes; this is a real departure from serde and limits how richly formats can express errors. Document this explicitly.

### 5. `Variant` serialization default

`Variant[A, B, C]` doesn't have a name or tag in Mojo. The plan emits externally-tagged JSON `{"TypeName": payload}` using `name_of[T]()` of the active arm. Confirm this gives readable output for the types you care about, and document the escape hatch (manual `Serialize` impl) for users who want something else (untagged, internally tagged).

### 6. Where-clause workarounds

Several places in this plan benefit from `where` clauses to constrain generic types. EmberJson's experience ([emberjson/lazy.mojo:112](emberjson/lazy.mojo#L112)) is that `where` clauses don't always work; the fallback is `comptime assert _type_is_eq[T, U]()` inside the function body. Plan to use the fallback when `where` fails, and don't litter the design with `where` clauses that might not compile.

### 7. Reflection on non-`@fieldwise_init` structs

EmberJson's deserialization has special handling for structs without a default constructor — it uses `__mlir_op.lit.ownership.mark_initialized` with an assertion that destructors are trivial ([emberjson/_deserialize/reflection.mojo:120](emberjson/_deserialize/reflection.mojo#L120)). The framework's `_default_deserialize` (Phase 4.4) needs the same escape hatch for types that aren't `Defaultable`. Carry this pattern over verbatim; don't re-invent it.

### 8. Second-format validation deferred

v1 ships JSON only. The `Deserializer` / `SelfDescribing` split is *designed* for multi-format, but the design isn't proven until a non-self-describing format (bincode-shaped) actually consumes the trait. **Mitigation**: in Phase 5, include a hand-rolled "token list" deserializer that implements `Deserializer` *without* `SelfDescribing`. Confirm that struct/list/map deserialization works and that attempting to deserialize a `Value` or `Coerce[Int64, ...]` against it fails at compile time with a useful error. This catches the design failure (e.g. `next_field_name` doesn't work for ordered formats) before a real binary format is on the line.

---

## Milestone summary

| Phase | Output | Rough scope |
|---|---|---|
| 1 | Package skeleton, pixi tasks green | small |
| 2 | Data model + error type | small |
| 3 | Serialization traits + reflection default + stdlib impls | medium |
| 4 | Deserialization traits (`Deserializer` + `SelfDescribing`) + reflection default + stdlib impls + `Coerce` adapter | medium |
| 5 | Debug-format reference + full framework tests | medium |
| 6 | EmberJson ported, deprecation aliases in place | medium |
| 7 | Benchmarks within 5% | small (or large if regression) |

Phases 1-5 produce a usable framework with no consumers. Phase 6 proves the abstraction. Phase 7 proves the cost is acceptable.
