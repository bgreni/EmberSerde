import emberserde
from std.collections import Set, Deque, LinkedList
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
    var l: List[String] = ["a", "bb"]
    assert_equal(debug_string(l), '["a", "bb"]')


def test_inline_array_of_int() raises:
    var a: InlineArray[Int, 3] = [1, 2, 3]
    assert_equal(debug_string(a), "(1, 2, 3)")


def test_inline_array_single_element() raises:
    var a: InlineArray[Int, 1] = [7]
    assert_equal(debug_string(a), "(7)")


def test_inline_array_of_string() raises:
    var a: InlineArray[String, 2] = ["a", "bb"]
    assert_equal(debug_string(a), '("a", "bb")')


# A `Set` rides the wire as a seq, so it renders with seq framing `[...]`, not
# `{...}`. Mojo's `Set` is `Dict`-backed and preserves insertion order, so the
# rendered strings are deterministic.
def test_set_of_int() raises:
    var s: Set[Int] = {1, 2, 3}
    assert_equal(debug_string(s), "[1, 2, 3]")


def test_empty_set() raises:
    var s = Set[Int]()
    assert_equal(debug_string(s), "[]")


def test_set_single_element() raises:
    var s = Set[Int](7)
    assert_equal(debug_string(s), "[7]")


def test_set_of_string() raises:
    var s: Set[String] = {"a", "bb"}
    assert_equal(debug_string(s), '["a", "bb"]')


def test_set_dedups() raises:
    var s = Set[Int]()
    s.add(1)
    s.add(2)
    s.add(1)
    assert_equal(debug_string(s), "[1, 2]")


# `Deque`/`LinkedList` ride the wire as seqs, same framing as `List`.
def test_deque_of_int() raises:
    var d = Deque[Int](1, 2, 3)
    assert_equal(debug_string(d), "[1, 2, 3]")


def test_deque_empty() raises:
    var d = Deque[Int]()
    assert_equal(debug_string(d), "[]")


def test_deque_of_string() raises:
    var d = Deque[String]("a", "bb")
    assert_equal(debug_string(d), '["a", "bb"]')


def test_linked_list_of_int() raises:
    var l = LinkedList[Int](1, 2, 3)
    assert_equal(debug_string(l), "[1, 2, 3]")


def test_linked_list_empty() raises:
    var l = LinkedList[Int]()
    assert_equal(debug_string(l), "[]")


def test_linked_list_of_string() raises:
    var l = LinkedList[String]("a", "bb")
    assert_equal(debug_string(l), '["a", "bb"]')


# A non-byte `Span` rides the wire as a seq.
def test_span_of_int() raises:
    var l: List[Int] = [1, 2, 3]
    assert_equal(debug_string(Span(l)), "[1, 2, 3]")


def test_span_empty() raises:
    var l = List[Int]()
    assert_equal(debug_string(Span(l)), "[]")


# A `Span[Byte]` routes through `serialize_bytes`, which the debug format
# renders with the `b[...]` framing.
def test_span_of_bytes() raises:
    var l: List[Byte] = [1, 2, 255]
    assert_equal(debug_string(Span(l)), "b[1, 2, 255]")


def test_span_of_bytes_empty() raises:
    var l = List[Byte]()
    assert_equal(debug_string(Span(l)), "b[]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
