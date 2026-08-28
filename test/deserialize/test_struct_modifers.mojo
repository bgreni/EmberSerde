from std.testing import assert_equal, assert_raises, TestSuite
from _debug_format import from_debug
from emberserde.field import field
from emberserde.struct_modifiers import (
    RenamePolicy,
    deny_unknown_fields,
    rename_all,
)


@rename_all(RenamePolicy.CamelCase)
@fieldwise_init
struct CamelRec(Copyable, Movable):
    var first_name: Int
    var age: Int


def test_rename_all_camel_matches_wire() raises:
    var r = from_debug[CamelRec]("CamelRec { firstName: 1, age: 2 }")
    assert_equal(r.first_name, 1)
    assert_equal(r.age, 2)


@rename_all(RenamePolicy.ScreamingSnakeCase)
@fieldwise_init
struct ScreamingSnakeRec(Copyable, Movable):
    var first_name: Int
    var age: Int


def test_rename_all_screaming_snake_matches_wire() raises:
    var r = from_debug[ScreamingSnakeRec](
        "ScreamingSnakeRec { FIRST_NAME: 1, AGE: 2 }"
    )
    assert_equal(r.first_name, 1)
    assert_equal(r.age, 2)


@rename_all(RenamePolicy.CamelCase)
@fieldwise_init
struct OverrideRec(Copyable, Movable):
    var first_name: Int

    @field(rename="kept")
    var keep_me: Int


def test_field_rename_overrides_policy() raises:
    var r = from_debug[OverrideRec]("OverrideRec { firstName: 1, kept: 2 }")
    assert_equal(r.first_name, 1)
    assert_equal(r.keep_me, 2)


@deny_unknown_fields
@fieldwise_init
struct Strict(Copyable, Movable):
    var a: Int


def test_deny_unknown_fields_raises() raises:
    with assert_raises():
        _ = from_debug[Strict]("Strict { a: 1, b: 2 }")


@fieldwise_init
struct Lax(Copyable, Movable):
    var a: Int


def test_unknown_field_skipped_by_default() raises:
    var r = from_debug[Lax]("Lax { a: 1, b: 2 }")
    assert_equal(r.a, 1)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
