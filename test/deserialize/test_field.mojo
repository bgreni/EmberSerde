from std.testing import assert_equal, assert_true, TestSuite, assert_raises
from _debug_format import from_debug
from emberserde.error import DerErrorKind
from emberserde.field import Alias, Default, Rename, Skip
from emberserde.validate import Validate
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


@fieldwise_init
struct Rec(Copyable, Movable):
    var a: Int

    @__annotation(Rename("b"))
    var renamed: Int

    @__annotation(Skip())
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

    @__annotation(Default(99))
    var d: Int

    @__annotation(Alias("e2"))
    var e: Int


def test_field_default_and_alias() raises:
    # `d` is absent -> default 99; `e` arrives under its alias "e2".
    var r = from_debug[Rec2]("Rec2 { a: 1, e2: 5 }")
    assert_equal(r.a, 1)
    assert_equal(r.d, 99)
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
struct Combined(Copyable, Movable):
    var a: Int

    @__annotation(Rename("b"), Alias("b2"), Default(7))
    var x: Int


def test_mixed_annotations_in_one_decorator() raises:
    assert_equal(from_debug[Combined]("Combined { a: 1, b: 2 }").x, 2)
    assert_equal(from_debug[Combined]("Combined { a: 1, b2: 3 }").x, 3)
    assert_equal(from_debug[Combined]("Combined { a: 1 }").x, 7)


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Rec3(Copyable, Movable):
    var a: Int

    @__annotation(Default(Point(3, 4)))
    var p: Point


def test_defaulted_non_defaultable_fills() raises:
    # `Point` has no zero-arg constructor; the explicit default value alone
    # must be enough to fill the missing field.
    var r = from_debug[Rec3]("Rec3 { a: 1 }")
    assert_equal(r.a, 1)
    assert_equal(r.p.x, 3)
    assert_equal(r.p.y, 4)


@fieldwise_init
struct Validated(Copyable, Movable):
    @__annotation(
        Validate(lambda (x: Int) -> Bool: x > 0),
        Validate(lambda (x: Int) -> Bool: x < 100),
    )
    var v: Int


def test_validate() raises:
    var r = from_debug[Validated]("Validated { v: 5 }")
    assert_equal(r.v, 5)
    # Every validator on the field must pass.
    for wire in ["Validated { v: -1 }", "Validated { v: 100 }"]:
        var kind = DerErrorKind.Custom
        try:
            _ = from_debug[Validated](wire)
        except err:
            kind = err.kind
        assert_equal(kind, DerErrorKind.InvalidValue)

    # This won't work until we can do conditional raises since I don't
    # want to burden this ctor with always raising.
    # with assert_raises():
    #     _ = Validated(-1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
