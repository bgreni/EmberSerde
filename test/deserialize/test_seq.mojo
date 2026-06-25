from std.collections import Set, Deque, LinkedList
from std.testing import assert_equal, assert_true, assert_false, TestSuite
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
    var r = from_debug[InlineArray[String, 2]]('("a", "bb")')
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


# A `Set` is carried as a seq, so the inputs use seq framing `[...]`.
def test_set_of_int() raises:
    var r = from_debug[Set[Int]]("[1, 2, 3]")
    assert_equal(len(r), 3)
    assert_true(1 in r)
    assert_true(2 in r)
    assert_true(3 in r)


def test_empty_set() raises:
    var r = from_debug[Set[Int]]("[]")
    assert_equal(len(r), 0)


def test_set_single_element() raises:
    var r = from_debug[Set[Int]]("[7]")
    assert_equal(len(r), 1)
    assert_true(7 in r)


def test_set_of_string() raises:
    var r = from_debug[Set[String]]('["a", "bb"]')
    assert_equal(len(r), 2)
    assert_true(String("a") in r)
    assert_true(String("bb") in r)
    assert_false(String("c") in r)


def test_set_dedups_on_deserialize() raises:
    var r = from_debug[Set[Int]]("[1, 1, 2]")
    assert_equal(len(r), 2)
    assert_true(1 in r)
    assert_true(2 in r)


def test_deque_of_int() raises:
    var r = from_debug[Deque[Int]]("[1, 2, 3]")
    assert_equal(len(r), 3)
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)
    assert_equal(r[2], 3)


def test_deque_empty() raises:
    var r = from_debug[Deque[Int]]("[]")
    assert_equal(len(r), 0)


def test_deque_of_string() raises:
    var r = from_debug[Deque[String]]('["a", "bb"]')
    assert_equal(len(r), 2)
    assert_equal(r[0], String("a"))
    assert_equal(r[1], String("bb"))


def test_linked_list_of_int() raises:
    var r = from_debug[LinkedList[Int]]("[1, 2, 3]")
    assert_equal(len(r), 3)
    assert_equal(r.get_nth(0), 1)
    assert_equal(r.get_nth(1), 2)
    assert_equal(r.get_nth(2), 3)


def test_linked_list_empty() raises:
    var r = from_debug[LinkedList[Int]]("[]")
    assert_equal(len(r), 0)


def test_linked_list_of_string() raises:
    var r = from_debug[LinkedList[String]]('["a", "bb"]')
    assert_equal(len(r), 2)
    assert_equal(r.get_nth(0), String("a"))
    assert_equal(r.get_nth(1), String("bb"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
