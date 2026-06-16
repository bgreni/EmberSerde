# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`emberserde` is a format-agnostic serialization framework for Mojo, *inspired by* Rust's serde but redesigned around Mojo's type system (reflection + `comptime if conforms_to`, no derive macros, no Visitor pattern). The end goal is to port [EmberJson](https://github.com/bgreni/EmberJson) onto it as the first consumer.

**[PLAN.md](PLAN.md) is the authoritative roadmap** — a detailed 7-phase plan with locked-in design decisions, dropped-feature rationale, and a list of design risks to validate. Read it before making architectural changes; do not re-litigate decisions recorded there. Note that PLAN.md describes the target design (package name `serde`, `Deserializer`/`SelfDescribing` split, `Value` ADT, `Coerce`); the actual package is `emberserde` and only part of the plan is built so far.

## Commands

```bash
pixi run test          # run all tests (python3 run_tests.py)
pixi run format        # mojo format -l 80 .
pixi run build         # mojo precompile emberserde -o emberserde.mojoc
pixi run precommit     # format + test
```

Run a single test file directly (this is what `run_tests.py` does per file):

```bash
mojo run -D ASSERT=all -I . -I test test/serialize/test_primitives.mojo
```

`run_tests.py` walks `test/` **recursively**, runs every `test_*.mojo` as its own `mojo` invocation, and skips helper modules (anything not matching `test_*.mojo`, e.g. `_debug_format.mojo`, which is importable but not executed). Tests are split into `test/serialize/` and `test/deserialize/`; the shared `_debug_format.mojo` helper stays at the `test/` root so both sides import it via `-I test`. Each test file ends with `TestSuite.discover_tests[__functions_in_module()]().run()`.

## Writing Mojo

Always use the `mojo-syntax` skill when writing or editing Mojo. This codebase uses current/nightly Mojo syntax that differs from older conventions: `comptime` (not `alias`), typed raises (`raises SerializationError`), `reflect[T]`, `conforms_to`, `Some[Trait]` generic args, `trait_downcast_var`, `__extension`.

**Mojo stdlib source is checked out locally at `~/Coding/mojo/mojo/stdlib/std/`** — read it directly when you need exact API signatures, trait conformances, or import paths (e.g. `OwnedPointer` lives in `memory/owned_pointer.mojo`, imported via `from std.memory import OwnedPointer`). It is more reliable than the IDE language server, which sometimes reports spurious "can't find a struct named ..." / "failed to resolve parent package" errors against perfectly valid stdlib imports; trust a `pixi run test`/build over those diagnostics.

## Architecture

The framework mirrors serde's "the type asks, the format delivers" split, adapted to Mojo:

- **`Serializable` / `Deserializer` traits** (per *type*): a Mojo type knows how to feed itself into a serializer / build itself from a deserializer.
- **`Serializer` / `Deserializer` traits** (per *format*): one method per data-model variant.
- **Reflection-driven default**: the public `serialize[T](value, mut s)` entry point does `comptime if conforms_to(T, Serializable): value.serialize(s) else: s.serialize_struct(value)`, where `serialize_struct` walks `reflect[T]` fields. This is how non-custom structs get serialized for free.

Module layout:
- [emberserde/serialize/](emberserde/serialize/) — `Serializer`/`Serializable` traits + state structs (`__init__.mojo`), stdlib `Serializable` impls (`impls.mojo`).
- [emberserde/deserialize/](emberserde/deserialize/) — `Deserializer`/state traits (in progress).
- [emberserde/error.mojo](emberserde/error.mojo) — `SerializationError`/`DeserializationError` (Mojo `raises` carries no payload, so a `kind` field is the typed dispatch).

### Two Mojo constraints that shape everything

1. **No parametric traits.** You cannot write `trait Serializer[W: Writer]`. Format-agnosticism is achieved with generic functions taking `Some[Serializer]` instead. See the comment in [emberserde/serialize/__init__.mojo](emberserde/serialize/__init__.mojo).
2. **No associated types on traits.** Serde's `SerializeSeq`/`SerializeMap`/`SerializeStruct` associated types are replaced by `comptime` members on the conforming struct (`comptime SeqType: SeqSerState`, etc.) plus separate state-struct traits (`SeqSerState`, `MapSerState`, `StructSerState`). `begin_seq`/`begin_map`/`begin_struct` return these state structs, which the caller drives with `serialize_element`/`serialize_field`/`end`.

### The debug format is the trait test-bed

[test/_debug_format.mojo](test/_debug_format.mojo) is a non-shipping, test-only `Serializer` that renders Rust-`Debug`-style output (`Foo { x: 1, y: "hi" }`). It is the **only** `Serializer` the framework owns, and exists to exercise every trait method so design flaws surface before a real format is on the line (PLAN.md §5.1). **If you can't implement the debug format cleanly against a trait, the trait is wrong — fix the trait, not the format.** It threads the output buffer as a safe `Pointer[String, origin]` rather than relying on origin-agnostic erasure.

## Mojo gotchas hit in this repo

These are recorded in persistent memory and are easy to re-trip:
- Linear/`@explicit_destroy` types break with generic `Some[Iterable]` loops — hence the manual `__iter__`/`__next__`/`trait_downcast_var` loop in `serialize_seq` instead of `for ref element in v`.
- Free-function vs method name collisions cause spurious recursion-candidate copy errors — qualify the free function (e.g. `emberserde.serialize.serialize(...)`).
- To return a type tied to `self`'s mutable origin from a mutating method, use `ref [origin] self`.
