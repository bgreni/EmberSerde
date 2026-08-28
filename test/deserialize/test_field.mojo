from std.testing import assert_equal, assert_true, TestSuite
from _debug_format import debug_string, from_debug
from emberserde.error import DerErrorKind
from emberserde.field import field


# Shadows the prelude name on purpose. `__is_optional` matches on `base_name`,
# which survives stdlib module moves that would break a fully-qualified path.
# The accepted cost of that stability: a user type merely *named* `Optional`
# also inherits absence-tolerance, and is default-filled when the wire omits it.
@fieldwise_init
struct Optional(Copyable, Defaultable, Movable):
    var x: Int

    def __init__(out self):
        self.x = 0


@fieldwise_init
struct FakeOptRec(Copyable, Movable):
    var a: Int
    var o: Optional


def test_user_type_named_optional_is_absence_tolerant() raises:
    var r = from_debug[FakeOptRec]("FakeOptRec { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.o.x, 0)


# Hand-written wire literals (per CLAUDE.md).
@fieldwise_init
struct Rec(Copyable, Movable):
    var a: Int

    @field(rename="b")
    var renamed: Int

    @field(skip=True)
    var hidden: Int


def test_field_rename_and_skip() raises:
    # "b" binds the renamed field; `hidden` is absent (skip) and fills via T().
    var r = from_debug[Rec]("Rec { a: 1, b: 2 }")
    assert_equal(r.a, 1)
    assert_equal(r.renamed, 2)
    assert_equal(r.hidden, 0)


@fieldwise_init
struct Rec2(Copyable, Movable):
    var a: Int

    @field(extra_names=List[String](["e2"]))
    var e: Int


def test_field_alias() raises:
    # `e` arrives under its alias "e2" rather than its own name.
    var r = from_debug[Rec2]("Rec2 { a: 1, e2: 5 }")
    assert_equal(r.a, 1)
    assert_equal(r.e, 5)


def test_alias_plus_primary_duplicate_raises() raises:
    # The primary name and an alias both bind the same field, so a wire
    # carrying both is a duplicate, not two fields.
    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[Rec2]("Rec2 { a: 1, e: 5, e2: 6 }")
    except err:
        kind = err.kind
    assert_equal(kind, DerErrorKind.DuplicateField)


@fieldwise_init
struct Rec4(Copyable, Defaultable, Movable):
    var a: Int

    @field(fill_if_missing=True)
    var b: String

    def __init__(out self):
        self.a = 0
        self.b = String()


def test_fill_if_missing_default_constructs() raises:
    # No explicit default value: absence fills via `T()` instead of raising.
    var r = from_debug[Rec4]("Rec4 { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.b, String())

    var present = from_debug[Rec4]('Rec4 { a: 1, b: "hi" }')
    assert_equal(present.b, String("hi"))


def test_undecorated_field_is_required() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[Rec4]('Rec4 { b: "hi" }')
    except err:
        kind = err.kind
    assert_equal(kind, DerErrorKind.MissingField)


@fieldwise_init
struct Rec5(Copyable, Defaultable, Movable):
    var a: Int

    @field(default=String("unknown"))
    var name: String

    def __init__(out self):
        self.a = 0
        self.name = String()


def test_field_default_value_used_when_absent() raises:
    # "unknown" differs from the default-constructed value ("" for String),
    # so this proves the decorator's *value* is used, not merely that some
    # fill happened to satisfy `fill_if_missing`.
    var r = from_debug[Rec5]("Rec5 { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.name, String("unknown"))

    var present = from_debug[Rec5]('Rec5 { a: 1, name: "given" }')
    assert_equal(present.name, String("given"))


@fieldwise_init
struct RecListDefault(Copyable, Defaultable, Movable):
    var a: Int

    # A collection-typed field carrying a value payload: the case
    # `field[FieldT: Base]`'s bound (`Movable & Deinitable`, not
    # `ImplicitlyCopyable`) exists to permit. `List`/`Dict` are `Copyable`
    # but not `ImplicitlyCopyable`, so a stronger bound would silently make
    # `@field(...)` unattachable here.
    @field(default=List[Int](1, 2, 3, __list_literal__=None))
    var xs: List[Int]

    def __init__(out self):
        self.a = 0
        self.xs = List[Int]()


def test_field_default_collection_value() raises:
    var r = from_debug[RecListDefault]("RecListDefault { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(len(r.xs), 3)
    assert_equal(r.xs[0], 1)
    assert_equal(r.xs[1], 2)
    assert_equal(r.xs[2], 3)


# A `skip_if` predicate must be a named top-level, non-capturing function.
def _is_empty_string(s: String) -> Bool:
    return s.byte_length() == 0


@fieldwise_init
struct RecSkipIfOnly(Copyable, Defaultable, Movable):
    var a: Int

    @field(skip_if=_is_empty_string)
    var name: String

    def __init__(out self):
        self.a = 0
        self.name = String()


def test_skip_if_alone_does_not_imply_fill() raises:
    # `skip_if` governs serialization only (whether the field reaches the
    # wire at all); deserialize never consults it. So a bare `skip_if` with
    # no `fill_if_missing`/`default` still requires the field on the wire,
    # mirroring serde's own `skip_serializing_if` + `default` pairing (the
    # first alone does not imply the second).
    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[RecSkipIfOnly]("RecSkipIfOnly { a: 1 }")
    except err:
        kind = err.kind
    assert_equal(kind, DerErrorKind.MissingField)


@fieldwise_init
struct RecSkipIfDefault(Copyable, Defaultable, Movable):
    var a: Int

    @field(skip_if=_is_empty_string, default=String("unknown"))
    var name: String

    def __init__(out self):
        self.a = 0
        self.name = String()


def test_skip_if_paired_with_default_round_trips_absence() raises:
    # Pairing `skip_if` with `default` is what makes the omission serde-style
    # round-trippable: absence fills with the decorator's value, not "".
    var r = from_debug[RecSkipIfDefault]("RecSkipIfDefault { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.name, String("unknown"))


@fieldwise_init
struct RecSkipDefault(Copyable, Defaultable, Movable):
    var a: Int

    # `skip=True` makes the field permanently absent from the wire —
    # `is_skipped` short-circuits `name_matches` to always `False` — and
    # `has_default` still wins over plain default-construction for the fill.
    # Named in the brief as a combination to pin explicitly.
    @field(skip=True, default=String("unknown"))
    var name: String

    def __init__(out self):
        self.a = 0
        self.name = String()


def test_skip_true_with_default_uses_explicit_value() raises:
    var r = from_debug[RecSkipDefault]("RecSkipDefault { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.name, String("unknown"))

    # Even if a wire value for the skipped field is present, `is_skipped`
    # keeps `name_matches` from ever binding it — the field is still filled
    # from `default`, not from the wire value.
    var with_wire_value = from_debug[RecSkipDefault](
        'RecSkipDefault { a: 1, name: "ignored" }'
    )
    assert_equal(with_wire_value.name, String("unknown"))


@fieldwise_init
struct RecSkipIfRoundTrip(Copyable, Defaultable, Movable):
    var a: Int

    @field(skip_if=_is_empty_string)
    var name: String

    def __init__(out self):
        self.a = 0
        self.name = String()


def test_skip_if_round_trip_missing_field_trap() raises:
    # The executable statement of the trap: serialize a value whose `name`
    # fires the predicate (so it never reaches the wire), feed *that exact
    # output* back into deserialize, and confirm it currently raises
    # `MissingField` — proving end to end, not just by inspection, that
    # `skip_if` alone does not make a field round-trippable. If `skip_if` is
    # ever changed to imply fill, this is the one test that flips.
    var wire = debug_string(RecSkipIfRoundTrip(a=1, name=String()))
    assert_equal(wire, "test_field.RecSkipIfRoundTrip { a: 1 }")

    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[RecSkipIfRoundTrip](wire)
    except err:
        kind = err.kind
    assert_equal(kind, DerErrorKind.MissingField)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
