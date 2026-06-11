# Deserialize `List` values (including nested and empty) from hand-written
# debug-format literals. The counterpart of `test_seq.mojo`. Inputs are spelled
# out explicitly rather than produced by the serializer.

from std.testing import assert_equal, TestSuite
from _debug_format import from_debug


def test_list_of_int() raises:
    var r = from_debug[List[Int]]("[1, 2, 3]")
    assert_equal(len(r), 3)
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)
    assert_equal(r[2], 3)


def test_empty_list() raises:
    var r = from_debug[List[Int]]("[]")
    assert_equal(len(r), 0)


def test_single_element() raises:
    var r = from_debug[List[Int]]("[7]")
    assert_equal(len(r), 1)
    assert_equal(r[0], 7)


def test_list_of_string() raises:
    var r = from_debug[List[String]]('["a", "bb"]')
    assert_equal(len(r), 2)
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


def test_nested_list() raises:
    var r = from_debug[List[List[Int]]]("[[1, 2], [3]]")
    assert_equal(len(r), 2)
    assert_equal(len(r[0]), 2)
    assert_equal(r[0][0], 1)
    assert_equal(r[0][1], 2)
    assert_equal(len(r[1]), 1)
    assert_equal(r[1][0], 3)


def test_inline_array_of_int() raises:
    # Statically-sized: rendered with the tuple framing `(...)`, not seq `[...]`.
    var r = from_debug[InlineArray[Int, 3]]("(1, 2, 3)")
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)
    assert_equal(r[2], 3)


def test_inline_array_single_element() raises:
    var r = from_debug[InlineArray[Int, 1]]("(7)")
    assert_equal(r[0], 7)


def test_inline_array_of_string() raises:
    # Heap-allocated elements: exercises move-init into uninitialized storage.
    var r = from_debug[InlineArray[String, 2]]('("a", "bb")')
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
