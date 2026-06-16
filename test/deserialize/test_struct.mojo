# Struct deserialization through the reflection-driven `expect_struct` default
# (the dual of the reflection-driven `serialize_struct`). Two ways in are
# exercised: a struct that opts in with a one-line `Deserializable` impl
# delegating to `expect_struct`, and a plain struct the framework default
# handles with no impl at all.
#
# Inputs are hand-written debug-format literals (never produced by the
# serializer), so the assertions pin the actual wire form and a symmetric
# encode/decode bug can't slip past undetected. The struct *name* in a literal
# is a free tag the reader ignores; only field names are matched, by name and
# not position. The default also carries field-evolution semantics: unknown
# fields are skipped, duplicates and missing required fields raise (with the
# matching `DerErrorKind`), and a missing `Optional` field falls back to empty.

from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from emberserde.deserialize import Deserializer, Deserializable
from emberserde.error import DeserializationError, DerErrorKind
from _debug_format import from_debug


# Opts in explicitly: a one-line `Deserializable` impl delegating to the
# framework default. `Defaultable` is required because `expect_struct` builds
# the value before filling its fields.
@fieldwise_init
struct Point(Copyable, Defaultable, Deserializable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_struct[Self]()


# Heterogeneous fields make name-vs-position matching observable: read
# positionally, `id` would try to parse `"ada"` and `active` would mismatch.
@fieldwise_init
struct Record(Copyable, Defaultable, Deserializable, Movable):
    var id: Int
    var name: String
    var active: Bool

    def __init__(out self):
        self.id = 0
        self.name = String()
        self.active = False

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_struct[Self]()


# No `Deserializable` impl and not `Defaultable`: the framework default handles
# it directly, exercising the `mark_initialized` escape hatch (all fields have
# trivial destructors).
@fieldwise_init
struct Pair(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct WithOpt(Copyable, Defaultable, Movable):
    var id: Int
    var note: Optional[Int64]

    def __init__(out self):
        self.id = 0
        self.note = None


def test_struct_fields() raises:
    var p = from_debug[Point]("Point { x: 1, y: 2 }")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_struct_inside_list() raises:
    # A struct nested in a sequence exercises recursion through both framings.
    var r = from_debug[List[Point]](
        "[Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]"
    )
    assert_equal(len(r), 2)
    assert_equal(r[0].x, 1)
    assert_equal(r[0].y, 2)
    assert_equal(r[1].x, 3)
    assert_equal(r[1].y, 4)


def test_fields_matched_by_name_not_position() raises:
    # Keys in reverse declaration order must map by name, not position.
    var p = from_debug[Point]("Pt { y: 20, x: 10 }")
    assert_equal(p.x, 10)
    assert_equal(p.y, 20)

    # Scrambled keys with distinct field types: positional reading would
    # mis-pair the values and the types wouldn't line up.
    var r = from_debug[Record]('Rec { name: "ada", active: true, id: 7 }')
    assert_equal(r.id, 7)
    assert_equal(r.name, String("ada"))
    assert_equal(r.active, True)


def test_unknown_field_skipped() raises:
    var p = from_debug[Pair]("P { x: 1, junk: 99, y: 2 }")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_unknown_nested_field_skipped() raises:
    # The skipped value contains nested braces, brackets, and a string with
    # separators in it — `skip_value` must consume it as one balanced unit.
    var p = from_debug[Pair](
        'P { junk: Foo { a: [1, 2], b: "x,y}" }, x: 1, y: 2 }'
    )
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_unknown_field_skipped_then_missing_raises() raises:
    # `z` is unknown and gets skipped; the raise is for the absent `y`.
    with assert_raises():
        _ = from_debug[Point]("Pt { x: 1, z: 2 }")


def test_duplicate_field_raises() raises:
    var kind = -1
    try:
        _ = from_debug[Pair]("P { x: 1, x: 2, y: 3 }")
    except e:
        kind = e.kind._kind
    assert_equal(kind, DerErrorKind.DuplicateField._kind)


def test_missing_field_raises() raises:
    var kind = -1
    try:
        _ = from_debug[Pair]("P { x: 1 }")
    except e:
        kind = e.kind._kind
    assert_equal(kind, DerErrorKind.MissingField._kind)


def test_missing_optional_field_defaults_to_none() raises:
    var w = from_debug[WithOpt]("W { id: 7 }")
    assert_equal(w.id, 7)
    assert_false(Bool(w.note))


def test_optional_field_present() raises:
    var w = from_debug[WithOpt]("W { id: 7, note: Some(9) }")
    assert_equal(w.id, 7)
    assert_true(Bool(w.note))
    assert_equal(w.note.value(), Int64(9))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
