from std.testing import assert_equal, assert_true, assert_false, TestSuite
from _debug_format import from_debug
from emberserde.field import field


@fieldwise_init
struct RenamedOpt(Copyable, Movable):
    var a: Int

    @field(rename="opt")
    var o: Optional[Int64]


def test_renamed_optional_absent() raises:
    # An `Optional` keeps absence-tolerance under a rename: a missing renamed
    # optional is None, not `MissingField`.
    var r = from_debug[RenamedOpt]("RenamedOpt { a: 1 }")
    assert_equal(r.a, 1)
    assert_false(Bool(r.o))


def test_renamed_optional_present() raises:
    var r = from_debug[RenamedOpt]("RenamedOpt { a: 1, opt: Some(5) }")
    assert_true(Bool(r.o))
    assert_equal(r.o.value(), Int64(5))


def test_some() raises:
    var v = from_debug[Optional[Int64]]("Some(5)")
    assert_true(Bool(v))
    assert_equal(v.value(), Int64(5))


def test_none() raises:
    var v = from_debug[Optional[Int64]]("None")
    assert_false(Bool(v))


def test_some_string() raises:
    var v = from_debug[Optional[String]]('Some("hi")')
    assert_true(Bool(v))
    assert_equal(v.value(), String("hi"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
