from std.builtin.rebind import downcast, rebind
from std.collections.string.string_span import get_static_string
from std.reflection import reflect

from emberserde.field import field
from emberserde.struct_modifiers import apply_rename_policy, rename_all
from emberserde.utils import Base


# Field `i`'s `@field(...)` attributes, or `None` when it carries none. A
# decorator is recorded as a comptime *value*, and at most one of a given type
# may sit on a declaration, so this is the whole handle.
#
# `field` takes one site-derived parameter (`FieldT`), bound by the compiler
# to the type of whatever `var` it decorates — never inferred from the
# arguments a particular `@field(...)` call passed. This is the one place
# that names the parameterization: every consumer below reads
# `field_dec[T, i]` and never spells `field[...]` itself, so `@field(rename=…)`
# and `@field(skip_if=…)` on the same field are still the *same* query
# (`field[FieldT]`), not two different ones that would each see only half the
# payload.
#
# `field_types()` is a `TypeList` erased to `AnyType` (the same shape Gap 5
# fixed for `decorator_types()`, but `field_types()` itself is untouched by
# that fix — it lives under `/Users/bgreni/Coding/mojo` and is out of scope
# here), so a plain `field[reflect[T].field_types()[i]]` does not typecheck:
# `field`'s parameter needs `Base`, and the list only proves `AnyType`. Every
# field reaching this point already has to conform to `Base` for
# serialize/deserialize to work at all (see `expect_struct`'s identical
# `downcast[r.field_types()[i], Base]`), so `downcast` here is asserting
# something already true elsewhere in the framework, not adding a new
# requirement.
comptime field_dec[T: AnyType, i: Int] = reflect[T].member_at[i].decorator_of[
    field[downcast[reflect[T].field_types()[i], Base]]
]()


# `Optional` fields are the one shape allowed to be absent on the wire: a
# missing optional field deserializes to its empty default instead of raising
# `MissingField`. Matched by qualified-name prefix so a user type merely
# *named* `Optional` doesn't inherit absence-tolerance. (A real type-identity
# test should replace this when the stdlib grows one — same mechanism as the
# `Span` byte specialization.)
def __is_optional[T: AnyType]() -> Bool:
    return reflect[T].base_name() == "Optional"


# The declared name reshaped by the struct's `rename_all` policy, or unchanged
# when the struct opts out. Field-level `rename` is applied separately and wins.
def _policy_name[T: AnyType](declared: StaticString) -> String:
    comptime d = reflect[T].decorator_of[rename_all]()
    comptime if d:
        return apply_rename_policy[d.value().policy](declared)
    return String(declared)


# Whether field `i` drops out of the wire entirely (`@field(skip=True)`).
def is_skipped[T: AnyType, i: Int]() -> Bool:
    comptime dec = field_dec[T, i]
    comptime if dec:
        return comptime (dec.value().skip)
    else:
        return False


# May field `i` be absent from the wire? `Optional` always; a decorated field
# when it is skipped or opts in with `fill_if_missing`. Everything else is
# required.
#
# Precedence when a field IS absent (see `has_default` and `expect_struct`):
# an explicit `@field(default=...)` value wins over plain `fill_if_missing`'s
# default-construct, and `@field(skip=True)` still implies fill (both are
# folded into `fill_if_missing` already, by `field.__init__`).
def fill_if_missing[T: AnyType, i: Int]() -> Bool:
    comptime dec = field_dec[T, i]
    comptime if __is_optional[reflect[T].field_types()[i]]():
        return True
    elif dec:
        return comptime (dec.value().fill_if_missing)
    else:
        return False


# Whether field `i` carries an explicit `@field(default=...)` value, as
# opposed to `fill_if_missing`'s bare default-construct. Only meaningful when
# `fill_if_missing[T, i]()` is also true; `expect_struct` reads this to choose
# between the supplied value and `type_of(f)()`.
def has_default[T: AnyType, i: Int]() -> Bool:
    comptime dec = field_dec[T, i]
    comptime if dec:
        return comptime (Bool(dec.value().default))
    else:
        return False


# Whether field `i`'s current runtime `value` should be omitted from the wire
# (`@field(skip_if=...)`). Unlike every other query in this file, this one is
# a *runtime* predicate over the field's actual value, not something
# computable from `T` and `i` alone — so unlike `is_skipped` (a static
# `skip=True`), a struct's visible field count can only be known exactly at
# serialize time, not up front (see `serialize/__init__.mojo`'s
# `serialize_struct`, and the `visible_fields` caveat below).
def should_skip_if[T: AnyType, i: Int, FieldT: Base](value: FieldT) -> Bool:
    comptime dec = field_dec[T, i]
    comptime if dec:
        comptime if dec.value().skip_if:
            # `FieldT` (this function's own, caller-inferred parameter) and
            # `field_dec[T, i]`'s internal `downcast[field_types()[i], Base]`
            # are the same concrete type at every real instantiation, but
            # they are two different symbolic expressions to the type
            # checker, so the predicate call needs an explicit `rebind`
            # rather than unifying automatically.
            comptime FT = downcast[reflect[T].field_types()[i], Base]
            var predicate = materialize[dec.value().skip_if.value()]()
            return predicate(rebind[FT](value))
    return False


# The wire name field `i` serializes under. Precedence: an explicit `rename` >
# the struct's `rename_all` policy > the declared name.
def wire_name[T: AnyType, i: Int]() -> String:
    comptime dec = field_dec[T, i]
    comptime if dec:
        comptime if dec.value().rename:
            return materialize[dec.value().rename.value()]()
    return _policy_name[T](reflect[T].member_at[i].name())


# `wire_name` computed at comptime and interned in static memory, so
# per-record work is a slice comparison — no `String` building.
def static_wire_name[T: AnyType, i: Int]() -> StaticString:
    return get_static_string[wire_name[T, i]()]()


# The wire names `T` actually emits (skipped fields drop out, rename/policy
# applied), in declaration order. This is the `begin_struct` contract for
# ordered/non-self-describing formats: serve exactly these names so the
# framework's name-matching loop in `expect_struct` binds every wire value —
# serving declared names instead silently breaks any struct using
# `rename`/`rename_all`/`skip`.
def wire_field_names[T: AnyType]() -> List[String]:
    var names = List[String]()
    comptime for i in range(reflect[T].field_count()):
        comptime if not is_skipped[T, i]():
            names.append(wire_name[T, i]())
    return names^


# Two fields resolving to the same wire name (a rename shadowing a declared
# name, or two identical renames) would silently bind first-declared-wins on
# deserialize and emit duplicate keys on serialize. `serialize_struct` and
# `expect_struct` comptime-assert on this so the collision fails the build,
# like serde's derive does.
def has_unique_wire_names[T: AnyType]() -> Bool:
    comptime count = reflect[T].field_count()
    comptime for i in range(count):
        comptime if not is_skipped[T, i]():
            var wire_i = wire_name[T, i]()
            comptime for j in range(i + 1, count):
                comptime if not is_skipped[T, j]():
                    if wire_i == wire_name[T, j]():
                        return False
    return True


# How many fields `T` actually emits — skipped (`@field(skip=True)`) fields
# drop out. This is a static upper bound, not an exact runtime count: a
# `@field(skip_if=...)` field may or may not be emitted depending on its
# value, and that can only be decided per-record in `serialize_struct`. It is
# still fine to hand to `begin_struct`'s `field_count` because every current
# format (debug/JSON/token) treats that count as informational — none size a
# wire structure from it — but a future format that DOES rely on an exact
# count would need a runtime-computed version of this function instead.
def visible_fields[T: AnyType]() -> Int:
    var visible = 0
    comptime for i in range(reflect[T].field_count()):
        comptime if not is_skipped[T, i]():
            visible += 1
    return visible


# Whether an incoming wire `name` binds field `i`: it matches the field's wire
# name (rename > policy > declared) or any explicit `extra_names` alias. A
# skipped field never matches. Aliases are taken verbatim — `rename_all` does
# not reshape them, mirroring serde. All candidate names are comptime-interned;
# the runtime work is slice comparisons only.
def name_matches[T: AnyType, i: Int](name: String) -> Bool:
    comptime if is_skipped[T, i]():
        return False
    if name == static_wire_name[T, i]():
        return True
    comptime dec = field_dec[T, i]
    comptime if dec:
        comptime if dec.value().extra_names:
            comptime extra = dec.value().extra_names.value()
            comptime for j in range(len(extra)):
                comptime al = get_static_string[extra[j]]()
                if name == al:
                    return True
    return False
