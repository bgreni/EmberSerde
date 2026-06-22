from std.builtin.rebind import downcast
from std.reflection import reflect

from emberserde.struct_modifiers import RenameAll, apply_rename_policy


# Field-attribute metadata, exposed as comptime members so the reflection
# defaults can read a `Field`'s rename/alias/skip/default config back off the
# erased field type via `downcast` — Mojo can't reflect on a type's comptime
# *parameters*, so the wrapper republishes them as members instead. Lives in its
# own module to break the `serialize`/`deserialize` <-> `field` import cycle.
trait FieldMeta(ImplicitlyDeletable, Movable):
    comptime serde_name: Optional[String]
    comptime serde_extra: Optional[List[String]]
    comptime serde_skip: Bool
    comptime serde_fill_if_missing: Bool


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
# not reshape them, mirroring serde.
def name_matches[
    T: AnyType, FT: AnyType
](declared: StaticString, name: String) -> Bool:
    comptime if conforms_to(FT, FieldMeta):
        comptime FM = downcast[FT, FieldMeta]
        comptime if FM.serde_skip:
            return False
        comptime if FM.serde_name:
            if name == FM.serde_name.value():
                return True
        else:
            if name == _policy_name[T](declared):
                return True
        comptime if FM.serde_extra:
            comptime extra = FM.serde_extra.value()
            comptime for j in range(len(extra)):
                comptime al = extra[j]
                if name == al:
                    return True
        return False
    else:
        return name == _policy_name[T](declared)
