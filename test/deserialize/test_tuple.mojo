import emberserde
from std.testing import assert_equal, assert_true, assert_false, TestSuite
from _debug_format import from_debug


def test_pair() raises:
    var t = from_debug[Tuple[Int, Int]]("(1, 2)")
    assert_equal(t[0], 1)
    assert_equal(t[1], 2)


def test_heterogeneous() raises:
    var t = from_debug[Tuple[Int, String, Bool]]('(1, "hi", true)')
    assert_equal(t[0], 1)
    assert_equal(t[1], String("hi"))
    assert_equal(t[2], True)


def test_nested_tuple() raises:
    var t = from_debug[Tuple[Int, Tuple[Int, Int]]]("(1, (2, 3))")
    assert_equal(t[0], 1)
    assert_equal(t[1][0], 2)
    assert_equal(t[1][1], 3)


def test_tuple_with_optional() raises:
    var t = from_debug[Tuple[Optional[Int64], Optional[Int64]]](
        "(Some(5), None)"
    )
    assert_true(Bool(t[0]))
    assert_equal(t[0].value(), Int64(5))
    assert_false(Bool(t[1]))


def test_heterogeneous_with_false() raises:
    var rebuilt = from_debug[Tuple[Int, String, Bool]]('(42, "ada", false)')
    assert_equal(rebuilt[0], 42)
    assert_equal(rebuilt[1], String("ada"))
    assert_equal(rebuilt[2], False)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
