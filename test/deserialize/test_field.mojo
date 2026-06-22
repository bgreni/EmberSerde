from std.testing import assert_equal, TestSuite
from _debug_format import from_debug
from emberserde.field import Defaulted, Field, Rename, Skip


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
    var e: Field[Int, extra_names=[String("e2")]]


def test_field_default_and_alias() raises:
    # `d` is absent -> default 99; `e` arrives under its alias "e2".
    var r = from_debug[Rec2]("Rec2 { a: 1, e2: 5 }")
    assert_equal(r.a, 1)
    assert_equal(r.d.value, 99)
    assert_equal(r.e.value, 5)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
