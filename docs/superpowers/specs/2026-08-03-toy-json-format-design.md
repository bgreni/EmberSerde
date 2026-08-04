# Toy JSON format — design

**Date:** 2026-08-03
**Status:** approved

## Purpose

Add a toy JSON format to the test suite as the third example format, alongside
`test/_debug_format.mojo` (self-describing text) and `test/_token_format.mojo`
(non-self-describing). Its job is to exercise the framework, not to be a real
JSON library: correctness and trait coverage are the goals; performance is
explicitly not.

JSON is the first format that pairs a **full recursive dynamic value** with
`SelfDescribingDeserializer`. The existing `test_self_describing.mojo` proves
the trait mechanics with a primitives-only `TinyValue` and stubbed containers;
the JSON format proves `deserialize_any` for arbitrary nested shapes — the
exact capability EmberJson's `Value` will need. Per the recorded decision
(REVIEW_FOLLOWUP.md), the dynamic value is **per-format** (`comptime Value =
JsonValue`); there is no shared framework ADT.

## File layout

Mirrors the token-format convention exactly:

- `test/_json_format.mojo` — helper module at the test root (importable via
  `-I test`, skipped by `run_tests.py`). Contains everything: `JsonValue`,
  `JsonSerializer` + five ser-state structs, `JsonDeserializer` + five
  de-state structs, `to_json[T]` / `from_json[T]` entry points.
- `test/serialize/test_json_format.mojo` — serializer tests (exact compact
  output strings).
- `test/deserialize/test_json_format.mojo` — deserializer tests (hand-written
  wire literals, per the CLAUDE.md rule) plus the `deserialize_any` /
  `JsonValue` tests, since the JSON format is the topic that owns them.

## Wire form

Output is **compact and canonical** (no whitespace) so round-trip string
equality is deterministic. The parser accepts arbitrary whitespace between
tokens.

| Data-model shape | JSON encoding |
| --- | --- |
| `Bool` | `true` / `false` |
| numbers | `String(v)` on output; `atol`/`atof` on input |
| `String` | quoted, minimal escapes: `\"` `\\` `\n` `\t` `\r` only |
| none / `null` | `null` |
| present `Optional` | the bare payload (serde_json convention) |
| bytes | array of numbers |
| seq | `[e1,e2,...]` — size hints ignored (self-describing) |
| tuple | `[e1,e2,...]` |
| map | `{"k":v,...}` |
| struct | `{"field":value,...}` — field names on the wire |
| enum | externally tagged: `{"Arm":payload}` (PLAN.md's example) |

Details and consequences:

- **Struct fields on the wire** means the framework's `expect_struct`
  name-matching loop, `Rename`/`RenameAll`, unknown-field `skip_value`, and
  missing-`Optional` fill all get exercised against a format that genuinely
  reads names (the token format can't skip; the debug format already covers
  the text-skipping case — JSON re-proves it with real JSON framing).
- **Non-string map keys** follow serde_json's stringify behavior: on
  serialize, the key is rendered into a temporary buffer and wrapped in
  quotes unless it already is a string. On deserialize, `expect_key` for a
  non-`String` key type consumes the opening quote, delegates to the nested
  deserializer for the contents, then consumes the closing quote, so
  `Dict[Int, _]` round-trips. (`String` keys go straight through
  `expect_string`.)
- **Enum:** `begin_enum` (de) consumes `{`, reads the key string, resolves it
  against `arm_names` to an index (unknown name → out-of-range index, which
  the `Variant` impl already turns into an error); `end` consumes `}`.
- **Optional:** `serialize_none` writes `null`; `serialize_some` writes the
  bare payload. `expect_optional` peeks for the `null` literal. Nested
  `Optional[Optional[T]]` is therefore ambiguous on this wire — accepted and
  documented, matching serde_json.
- **`expect_struct` is not overridden** — the framework's reflection-driven
  default drives the framing, as in the debug format.

## `JsonValue`

The format's `comptime Value` on `SelfDescribingDeserializer`:

- `Variant[JsonNull, Bool, Int64, Float64, String, List[JsonValue],
  Dict[String, JsonValue]]`, where `JsonNull` is an empty marker struct.
  `List`/`Dict` provide the recursion indirection (same shape as EmberJson's
  `Value`).
- Predicates (`is_null`, `is_bool`, `is_int`, `is_float`, `is_string`,
  `is_array`, `is_object`) and accessors, mirroring `TinyValue`.
- `Deserializable`: the `comptime if conforms_to(type_of(d),
  SelfDescribingDeserializer)` + `rebind_var` pattern from `TinyValue`; a
  non-self-describing format takes the `else` branch and raises.
- `Serializable`: matches arms onto serializer calls — `JsonNull` →
  `serialize_none`, `Bool`/numbers/`String` → the primitive methods, array →
  `begin_seq`, object → `begin_map`. This makes parse → re-serialize
  round-trip tests possible and mirrors what EmberJson's `Value` will do.
- `deserialize_any` dispatches on the first non-whitespace character:
  `{` → object, `[` → array, `"` → string, `t`/`f` → bool, `n` → null,
  otherwise number. A number lexes to `Int64` unless it contains `.`, `e`,
  or `E`, in which case `Float64`.

## Plumbing

Same safe-pointer pattern as both existing formats:

- Serializer side: `JsonSerializer[origin]` holds `Pointer[String, origin]`
  to the output buffer; state structs carry the same pointer and recursion
  reconstructs a `JsonSerializer` over the shared buffer.
- Deserializer side: `JsonCursor` (buf + pos, with `peek`/`advance`/
  `skip_ws`/literal helpers, modeled on `DebugCursor`) shared via
  `Pointer[JsonCursor, origin]`.

## Error handling

Every parse failure raises `DeserializationError` with a specific message:
`TypeMismatch` for wrong-shape input (e.g. `expect_bool` seeing `[`),
`InvalidValue` for malformed text (unterminated string, bad number, garbage
literal). A truncated or unrecognized bare literal (e.g. `tru`) reports
`TypeMismatch` — the leading byte already promised a bool shape — while
`InvalidValue` covers malformed text within an otherwise-established shape.
`end()` methods strictly consume their closing delimiter and raise if absent.
No aborts, no silent recovery.

## Testing

Serialize tests assert exact compact output strings. Deserialize tests feed
hand-written wire literals — never serializer output — so a symmetric
encode/decode bug cannot round-trip past an assertion. Coverage:

- primitives; strings containing each supported escape
- seq / map / nested containers; tuple
- structs: nested, `Rename`/`RenameAll`, unknown-field skipping,
  missing-`Optional` fill, `DenyUnknownFields`
- enum (externally tagged), including unknown-arm error
- `Optional` (`null` and bare payload), bytes
- non-string map keys (`Dict[Int, _]`) both directions
- `deserialize_any`: every arm, including nested object/array
- `conforms_to(JsonDeserializer[...], SelfDescribingDeserializer)` holds
- `JsonValue` round-trip: parse arbitrary JSON → re-serialize → string
  equality (insertion-ordered `Dict` keeps key order stable)
- whitespace tolerance on input; malformed-input error cases (each raises,
  with the expected kind)

## Out of scope

- Performance of any kind (no benchmarks, no zero-copy).
- Spec-complete strings: `\uXXXX`, surrogate pairs, `\b` `\f`, control-char
  escaping on output.
- Shipping this format in the `emberserde` package — it lives in `test/`
  only. The real JSON consumer remains the future EmberJson port.
