from std.builtin.rebind import downcast
from std.collections.string.string_span import get_static_string
from std.reflection import reflect

from emberserde.error import DeserializationError, DerErrorKind
from emberserde.struct_modifiers import (
    DenyUnknownFields,
    RenameAll,
    apply_rename_policy,
)


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
    return reflect[T].base_name() == "Optional"


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
    comptime if conforms_to(T, RenameAll):
        return apply_rename_policy[downcast[T, RenameAll].FieldRenamePolicy](
            declared
        )
    else:
        return String(declared)


# `wire_name` computed at comptime and interned in static memory, so
# per-record work is a slice comparison — no `String` building.
def static_wire_name[
    T: AnyType, FT: AnyType, declared: StaticString
]() -> StaticString:
    return get_static_string[wire_name[T, FT](declared)]()


# The wire names `T` actually emits (skipped fields drop out, rename/policy
# applied), in declaration order.
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
    var names = wire_field_names[T]()
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            if names[i] == names[j]:
                return False
    return True


# `name == W` for a comptime-known `W`, specialized on `W`'s length. Wire keys
# are short, and the generic slice comparison runs a byte-at-a-time `memcmp`
# loop below 16 bytes; here the length test is one compare against a constant
# and the contents are at most a few overlapping word loads.
@always_inline
def _word_eq[
    DT: DType, off: Int
](a: ImmPointer[Byte, ...], b: ImmPointer[Byte, ...]) -> Bool:
    return (
        a.unsafe_offset(off).unsafe_bitcast[Scalar[DT]]()[]
        == b.unsafe_offset(off).unsafe_bitcast[Scalar[DT]]()[]
    )


@always_inline
def _eq_static[W: StaticString](name: StringSlice) -> Bool:
    comptime L = W.byte_length()
    if name.byte_length() != L:
        return False
    var p = name.unsafe_ptr()
    var q = W.unsafe_ptr()
    comptime if L == 0:
        return True
    elif L < 4:
        comptime for i in range(L):
            if p[unsafe_offset=i] != q[unsafe_offset=i]:
                return False
        return True
    elif L < 8:
        return _word_eq[DType.uint32, 0](p, q) and _word_eq[
            DType.uint32, L - 4
        ](p, q)
    else:
        comptime for k in range(L // 8):
            if not _word_eq[DType.uint64, k * 8](p, q):
                return False
        comptime if L % 8 != 0:
            return _word_eq[DType.uint64, L - 8](p, q)
        return True


# Whether an incoming wire `name` binds field `i`: it matches the field's wire
# name (rename > policy > declared) or any explicit `extra_names` alias. A
# skipped field never matches. Aliases are taken verbatim — `rename_all` does
# not reshape them, mirroring serde. All candidate names are comptime-interned;
# the runtime work is slice comparisons only.
def name_matches[
    T: AnyType, FT: AnyType, declared: StaticString
](name: StringSlice) -> Bool:
    comptime if is_skipped[FT]():
        return False
    if _eq_static[static_wire_name[T, FT, declared]()](name):
        return True
    comptime if conforms_to(FT, FieldMeta):
        comptime FM = downcast[FT, FieldMeta]
        comptime if FM.serde_extra:
            comptime extra = FM.serde_extra.value()
            comptime for j in range(len(extra)):
                comptime al = get_static_string[extra[j]]()
                if _eq_static[al](name):
                    return True
    return False


# What `StructDerState.expect_field_index` returns for a wire key that binds
# no field of `T`.
comptime UNKNOWN_FIELD = -1


# How a self-describing format turns a wire key into the declaration index
# `expect_field_index` must return. Takes a slice so a key can be resolved
# straight out of the input buffer. Raising here (rather than in
# `expect_struct`) keeps the offending name in the `DenyUnknownFields` error —
# the framework only ever sees the index.
def field_index[
    T: AnyType
](name: StringSlice) raises DeserializationError -> Int:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime declared = r.field_names()[i]
        if name_matches[T, r.field_types()[i], declared](name):
            return i
    comptime if conforms_to(T, DenyUnknownFields):
        raise DeserializationError(
            String(t"Unknown field: {name}"),
            DerErrorKind.UnknownField,
        )
    else:
        return UNKNOWN_FIELD


# How an ordered/non-self-describing format walks `T`: the declaration index
# of the first non-skipped field at or after `start`, `None` when there is
# none. Skipped fields never reach the wire, so stepping `0, 1, 2, ...`
# instead would misalign every value after a `Skip`.
def next_wire_field[T: AnyType](start: Int) -> Optional[Int]:
    comptime r = reflect[T]
    comptime for i in range(r.field_count()):
        comptime if not is_skipped[r.field_types()[i]]():
            if i >= start:
                return i
    return None
