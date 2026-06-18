import emberserde
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


def test_pair() raises:
    assert_equal(debug_string((1, 2)), "(1, 2)")


def test_heterogeneous() raises:
    assert_equal(debug_string((1, String("hi"), True)), '(1, "hi", true)')


def test_single_element() raises:
    assert_equal(debug_string((7,)), "(7)")


def test_nested_tuple() raises:
    assert_equal(debug_string((1, (2, 3))), "(1, (2, 3))")


def test_tuple_of_list() raises:
    var xs: List[Int] = [1, 2]
    assert_equal(debug_string((xs^, String("x"))), '([1, 2], "x")')


def test_tuple_with_optional() raises:
    assert_equal(
        debug_string((Optional(Int64(5)), Optional[Int64](None))),
        "(Some(5), None)",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
