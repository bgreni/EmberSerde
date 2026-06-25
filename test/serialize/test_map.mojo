from std.collections import Counter
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


def test_dict_string_keys() raises:
    var d = {"a": 1, "b": 2}
    assert_equal(debug_string(d), '{"a": 1, "b": 2}')


def test_dict_empty() raises:
    var d = Dict[String, Int]()
    assert_equal(debug_string(d), "{}")


def test_dict_int_keys() raises:
    var d = {1: 10, 2: 20}
    assert_equal(debug_string(d), "{1: 10, 2: 20}")


def test_dict_of_list() raises:
    var d = Dict[String, List[Int]]()
    d["xs"] = [1, 2]
    assert_equal(debug_string(d), '{"xs": [1, 2]}')


# A `Counter` rides the wire as a map of `value -> count`. It is `Dict`-backed,
# so insertion order is preserved and the rendered output is deterministic.
def test_counter_string_keys() raises:
    var c = Counter[String]("a", "a", "a", "b", "b")
    assert_equal(debug_string(c), '{"a": 3, "b": 2}')


def test_counter_int_keys() raises:
    var c = Counter[Int](1, 1, 2)
    assert_equal(debug_string(c), "{1: 2, 2: 1}")


def test_counter_empty() raises:
    var c = Counter[String]()
    assert_equal(debug_string(c), "{}")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
