from std.builtin.rebind import downcast
from std.collections.string.string_span import get_static_string
from std.reflection import reflect

from emberserde.struct_modifiers import RenameAll, apply_rename_policy


# Field-attribute metadata, exposed as comptime members so the reflection
# defaults can read a `Field`'s rename/alias/skip/default config back off the
# erased field type via `downcast` — Mojo can't reflect on a type's comptime
# *parameters*, so the wrapper republishes them as members instead. Lives in its
# own module to break the `serialize`/`deserialize` <-> `field` import cycle.
trait FieldMeta(Deinitable, Movable):
    comptime serde_name: Optional[String]
    comptime serde_extra: Optional[List[String]]
    comptime serde_skip: Bool
    comptime serde_fill_if_missing: Bool

    # The value a missing/skipped field materializes as: the explicit
    # `default` if given, else `T()`. Lives here (not on `Defaultable`)
    # because an explicit default needs no `T()` — `Defaulted[T, v]` of a
    # non-Defaultable `T` still fills. `Field` comptime-asserts inside when
    # neither exists, i.e. exactly when the field genuinely cannot be filled.
    @staticmethod
    def serde_filled() -> Self:
        ...


# `Optional` fields are the one shape allowed to be absent on the wire: a
# missing optional field deserializes to its empty default instead of raising
# `MissingField`. Matched by qualified-name prefix so a user type merely
# *named* `Optional` doesn't inherit absence-tolerance. (A real type-identity
# test should replace this when the stdlib grows one — same mechanism as the
# `Span` byte specialization.)
def __is_optional[T: AnyType]() -> Bool:
    return reflect[T].name().startswith("std.collections.optional.Optional[")


# The declared name reshaped by the struct's `rename_all` policy, or unchanged
# when the struct opts out. Field-level `rename` is applied separately and wins.
def _policy_name[T: AnyType](declared: StaticString) -> String:
    comptime if conforms_to(T, RenameAll):
        return apply_rename_policy[downcast[T, RenameAll].FieldRenamePolicy](
            declared
        )
    else:
        return String(declared)


# Whether field `i` drops out of the wire entirely (`Field[..., skip=True]`).
def is_skipped[FT: AnyType]() -> Bool:
    comptime if conforms_to(FT, FieldMeta):
        return downcast[FT, FieldMeta].serde_skip
    else:
        return False


# The wire name field `i` serializes under. Precedence: a `Field`'s explicit
# `rename` > the struct's `rename_all` policy > the declared name.
def wire_name[T: AnyType, FT: AnyType](declared: StaticString) -> String:
    comptime if conforms_to(FT, FieldMeta):
        comptime FM = downcast[FT, FieldMeta]
        comptime if FM.serde_name:
            return String(FM.serde_name.value())
    return _policy_name[T](declared)


# `wire_name` computed at comptime and interned in static memory, so
# per-record work is a slice comparison — no `String` building.
def static_wire_name[
    T: AnyType, FT: AnyType, declared: StaticString
]() -> StaticString:
    return get_static_string[wire_name[T, FT](declared)]()


# The wire names `T` actually emits (skipped fields drop out, rename/policy
# applied), in declaration order. This is the `begin_struct` contract for
# ordered/non-self-describing formats: serve exactly these names so the
# framework's name-matching loop in `expect_struct` binds every wire value —
# serving declared names instead silently breaks any struct using
# `Rename`/`RenameAll`/`Skip`.
def wire_field_names[T: AnyType]() -> List[String]:
    var names = List[String]()
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime FT = r.field_types()[i]
        comptime if not is_skipped[FT]():
            comptime declared = r.field_names()[i]
            names.append(wire_name[T, FT](declared))
    return names^


# Two fields resolving to the same wire name (a rename shadowing a declared
# name, or two identical renames) would silently bind first-declared-wins on
# deserialize and emit duplicate keys on serialize. `serialize_struct` and
# `expect_struct` comptime-assert on this so the collision fails the build,
# like serde's derive does.
def has_unique_wire_names[T: AnyType]() -> Bool:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime if not is_skipped[r.field_types()[i]]():
            comptime name_i = r.field_names()[i]
            var wire_i = wire_name[T, r.field_types()[i]](name_i)
            comptime for j in range(i + 1, r.field_count()):
                comptime if not is_skipped[r.field_types()[j]]():
                    comptime name_j = r.field_names()[j]
                    if wire_i == wire_name[T, r.field_types()[j]](name_j):
                        return False
    return True


# How many fields `T` actually emits — skipped `Field`s drop out.
def visible_fields[T: AnyType]() -> Int:
    var visible = 0
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime if not is_skipped[r.field_types()[i]]():
            visible += 1
    return visible


# Whether an incoming wire `name` binds field `i`: it matches the field's wire
# name (rename > policy > declared) or any explicit `extra_names` alias. A
# skipped field never matches. Aliases are taken verbatim — `rename_all` does
# not reshape them, mirroring serde. All candidate names are comptime-interned;
# the runtime work is slice comparisons only.
def name_matches[
    T: AnyType, FT: AnyType, declared: StaticString
](name: String) -> Bool:
    comptime if is_skipped[FT]():
        return False
    if name == static_wire_name[T, FT, declared]():
        return True
    comptime if conforms_to(FT, FieldMeta):
        comptime FM = downcast[FT, FieldMeta]
        comptime if FM.serde_extra:
            comptime extra = FM.serde_extra.value()
            comptime for j in range(len(extra)):
                comptime al = get_static_string[extra[j]]()
                if name == al:
                    return True
    return False
