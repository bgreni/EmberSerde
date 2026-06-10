# Serialize `List` values (including nested and empty) through the debug format.

import emberserde
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string, DebugSerializer


def test_list_of_int() raises:
    var l: List[Int] = [1, 2, 3]
    assert_equal(debug_string(l), "[1, 2, 3]")


def test_empty_list() raises:
    var l = List[Int]()
    assert_equal(debug_string(l), "[]")


def test_single_element() raises:
    var l: List[Int] = [7]
    assert_equal(debug_string(l), "[7]")


def test_list_of_string() raises:
    var l: List[String] = ["a", "bb"]
    assert_equal(debug_string(l), '["a", "bb"]')


def test_nested_list() raises:
    var inner0: List[Int] = [1, 2]
    var inner1: List[Int] = [3]
    var outer = List[List[Int]]()
    outer.append(inner0^)
    outer.append(inner1^)
    assert_equal(debug_string(outer), "[[1, 2], [3]]")


def test_serialize_seq_empty() raises:
    var l = List[Int]()
    assert_equal(debug_string(l), "[]")


def test_serialize_seq_of_string() raises:
    # Heap-allocated elements: exercises the destructor on the cleanup path.
    var l: List[String] = ["a", "bb"]
    assert_equal(debug_string(l), '["a", "bb"]')


def test_inline_array_of_int() raises:
    var a: InlineArray[Int, 3] = [1, 2, 3]
    assert_equal(debug_string(a), "[1, 2, 3]")


def test_inline_array_single_element() raises:
    var a: InlineArray[Int, 1] = [7]
    assert_equal(debug_string(a), "[7]")


def test_inline_array_of_string() raises:
    var a: InlineArray[String, 2] = ["a", "bb"]
    assert_equal(debug_string(a), '["a", "bb"]')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
