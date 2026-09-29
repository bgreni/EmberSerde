from std.builtin.rebind import downcast
from std.collections.string.string_span import get_static_string
from std.reflection import reflect

from emberserde.error import DeserializationError, DerErrorKind
from emberserde.field import Alias, Rename, Skip, TypedAnnotation
from emberserde.struct_modifiers import (
    DenyUnknownFields,
    RenameAll,
    apply_rename_policy,
    count_struct_annotations,
    struct_annotations,
)


# Field `i`'s annotations, bound at comptime: indexing the tuple at runtime
# would materialize every value in it.
comptime field_annotations[T: AnyType, i: Int] = reflect[T].field_annotations[
    i
]()


# How many annotations of type `A` field `i` carries. Every lookup goes
# through here, so it is also where a mistyped `Default`/`Validate` fails.
def count_annotations[T: AnyType, i: Int, A: AnyType]() -> Int:
    comptime Ts = type_of(field_annotations[T, i]).Ts
    var n = 0
    comptime for j in range(Ts.length):
        comptime if conforms_to(Ts[j], TypedAnnotation):
            comptime assert (
                downcast[Ts[j], TypedAnnotation].Type
                == reflect[T].field_types()[i]
            ), (
                "a typed annotation (Default, Transform, SerializeWith,"
                " Validate, Range, Eq, Enum) must match its field's type"
                " exactly"
            )
        comptime if Ts[j] == A:
            n += 1
    return n


# `Optional` fields are the one shape allowed to be absent on the wire: a
# missing optional field deserializes to its empty default instead of raising
# `MissingField`. Matched by qualified-name prefix so a user type merely
# *named* `Optional` doesn't inherit absence-tolerance. (A real type-identity
# test should replace this when the stdlib grows one — same mechanism as the
# `Span` byte specialization.)
def __is_optional[T: AnyType]() -> Bool:
    return reflect[T].base_name() == "Optional"


# Whether field `i` drops out of the wire entirely (`Skip`).
def is_skipped[T: AnyType, i: Int]() -> Bool:
    return count_annotations[T, i, Skip]() > 0


# The wire name field `i` serializes under. Precedence: a `Rename` >
# the struct's `rename_all` policy > the declared name.
def wire_name[T: AnyType, i: Int]() -> String:
    comptime assert (
        count_annotations[T, i, Rename]() <= 1
    ), "a field may carry at most one Rename"
    comptime anns = field_annotations[T, i]
    comptime Ts = type_of(anns).Ts
    comptime for j in range(Ts.length):
        comptime if Ts[j] == Rename:
            comptime name = rebind[Rename](anns[j]).name
            return String(name)
    comptime declared = reflect[T].field_names()[i]
    comptime assert (
        count_struct_annotations[T, RenameAll]() <= 1
    ), "a struct may carry at most one RenameAll"
    comptime sanns = struct_annotations[T]
    comptime STs = type_of(sanns).Ts
    comptime for j in range(STs.length):
        comptime if STs[j] == RenameAll:
            comptime policy = rebind[RenameAll](sanns[j]).policy
            return apply_rename_policy[policy](declared)
    return String(declared)


# `wire_name` computed at comptime and interned in static memory, so
# per-record work is a slice comparison — no `String` building.
def static_wire_name[T: AnyType, i: Int]() -> StaticString:
    return get_static_string[wire_name[T, i]()]()


# The wire names `T` actually emits (skipped fields drop out, rename/policy
# applied), in declaration order.
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
# name (rename > policy > declared) or any `Alias`. A skipped field never
# matches. Aliases are taken verbatim — `rename_all` does not reshape them,
# mirroring serde. All candidate names are comptime-interned; the runtime work
# is slice comparisons only.
def name_matches[T: AnyType, i: Int](name: StringSlice) -> Bool:
    comptime if is_skipped[T, i]():
        return False
    if _eq_static[static_wire_name[T, i]()](name):
        return True
    comptime anns = field_annotations[T, i]
    comptime Ts = type_of(anns).Ts
    comptime for j in range(Ts.length):
        comptime if Ts[j] == Alias:
            comptime al = rebind[Alias](anns[j]).name
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
    comptime for i in range(reflect[T].field_count()):
        if name_matches[T, i](name):
            return i
    comptime if count_struct_annotations[T, DenyUnknownFields]() > 0:
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
    comptime for i in range(reflect[T].field_count()):
        comptime if not is_skipped[T, i]():
            if i >= start:
                return i
    return None
