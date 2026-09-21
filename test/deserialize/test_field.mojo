from std.testing import assert_equal, assert_true, TestSuite, assert_raises
from _debug_format import from_debug
from emberserde.error import DerErrorKind
from emberserde.field import Defaulted, Field, Rename, Skip
from emberserde.error import DeserializationError


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


# Hand-written wire literals (per CLAUDE.md). A bare `Field` reads as its inner
# value; attributes only bite inside a struct.
def test_field_deserializes_transparently() raises:
    assert_equal(from_debug[Field[Int]]("5").value, 5)
    assert_equal(from_debug[Field[String]]('"hi"').value, "hi")


@fieldwise_init
struct Rec(Copyable, Movable):
    var a: Int
    var renamed: Rename[Int, String("b")]
    var hidden: Skip[Int]


def test_field_rename_and_skip() raises:
    # "b" binds the renamed field; `hidden` is absent (skip) and fills via T().
    var r = from_debug[Rec]("Rec { a: 1, b: 2 }")
    assert_equal(r.a, 1)
    assert_equal(r.renamed.value, 2)
    assert_equal(r.hidden.value, 0)


@fieldwise_init
struct Rec2(Copyable, Movable):
    var a: Int
    var d: Defaulted[Int, Int(99)]
    var e: Field[Int, extra_names=List[String]([String("e2")])]


def test_field_default_and_alias() raises:
    # `d` is absent -> default 99; `e` arrives under its alias "e2".
    var r = from_debug[Rec2]("Rec2 { a: 1, e2: 5 }")
    assert_equal(r.a, 1)
    assert_equal(r.d.value, 99)
    assert_equal(r.e.value, 5)


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
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Rec3(Copyable, Movable):
    var a: Int
    var p: Defaulted[Point, Point(3, 4)]


def test_defaulted_non_defaultable_fills() raises:
    # `Point` has no zero-arg constructor; the explicit default value alone
    # must be enough to fill the missing field.
    var r = from_debug[Rec3]("Rec3 { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.p[].x, 3)
    assert_equal(r.p[].y, 4)


comptime Validated = Field[Int, validate=lambda (x: Int) -> Bool: x > 0]


def test_validate() raises:
    var r = from_debug[Validated]("5")
    assert_equal(r.value, 5)
    with assert_raises():
        _ = from_debug[Validated]("-1")

    # This won't work until we can do conditional raises since I don't
    # want to burden this ctor with always raising.
    # with assert_raises():
    #     _ = Validated(-1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
