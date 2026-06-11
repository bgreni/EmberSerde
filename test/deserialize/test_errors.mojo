# Field-evolution semantics of the framework's reflection-driven
# `expect_struct` default: unknown fields are skipped, duplicates and missing
# required fields raise (with the matching `DerErrorKind`), and missing
# `Optional` fields fall back to empty instead of raising.

from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    assert_raises,
    TestSuite,
)
from emberserde.error import DeserializationError, DerErrorKind
from _debug_format import from_debug


# Not `Defaultable`: exercises the `mark_initialized` escape hatch in the
# framework default (all fields have trivial destructors).
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
