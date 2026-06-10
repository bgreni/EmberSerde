# Round-trip `List` values (including nested and empty) through the debug format.
# The counterpart of `test_seq.mojo`.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string, from_debug


def test_list_of_int() raises:
    var l: List[Int] = [1, 2, 3]
    var r = from_debug[List[Int]](debug_string(l))
    assert_equal(len(r), 3)
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)
    assert_equal(r[2], 3)


def test_empty_list() raises:
    var l = List[Int]()
    var r = from_debug[List[Int]](debug_string(l))
    assert_equal(len(r), 0)


def test_single_element() raises:
    var l: List[Int] = [7]
    var r = from_debug[List[Int]](debug_string(l))
    assert_equal(len(r), 1)
    assert_equal(r[0], 7)


def test_list_of_string() raises:
    var l: List[String] = ["a", "bb"]
    var r = from_debug[List[String]](debug_string(l))
    assert_equal(len(r), 2)
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


def test_nested_list() raises:
    var inner0: List[Int] = [1, 2]
    var inner1: List[Int] = [3]
    var outer = List[List[Int]]()
    outer.append(inner0^)
    outer.append(inner1^)
    var r = from_debug[List[List[Int]]](debug_string(outer))
    assert_equal(len(r), 2)
    assert_equal(len(r[0]), 2)
    assert_equal(r[0][0], 1)
    assert_equal(r[0][1], 2)
    assert_equal(len(r[1]), 1)
    assert_equal(r[1][0], 3)


def test_inline_array_of_int() raises:
    var a: InlineArray[Int, 3] = [1, 2, 3]
    var r = from_debug[InlineArray[Int, 3]](debug_string(a))
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)
    assert_equal(r[2], 3)


def test_inline_array_single_element() raises:
    var a: InlineArray[Int, 1] = [7]
    var r = from_debug[InlineArray[Int, 1]](debug_string(a))
    assert_equal(r[0], 7)


def test_inline_array_of_string() raises:
    # Heap-allocated elements: exercises move-init into uninitialized storage.
    var a: InlineArray[String, 2] = ["a", "bb"]
    var r = from_debug[InlineArray[String, 2]](debug_string(a))
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
