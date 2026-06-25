from std.collections import Counter
from std.testing import assert_equal, TestSuite
from _debug_format import from_debug


def test_dict_string_keys() raises:
    var r = from_debug[Dict[String, Int]]('{"a": 1, "b": 2}')
    assert_equal(len(r), 2)
    assert_equal(r["a"], 1)
    assert_equal(r["b"], 2)


def test_dict_empty() raises:
    var r = from_debug[Dict[String, Int]]("{}")
    assert_equal(len(r), 0)


def test_dict_int_keys() raises:
    var r = from_debug[Dict[Int, Int]]("{1: 10, 2: 20}")
    assert_equal(len(r), 2)
    assert_equal(r[1], 10)
    assert_equal(r[2], 20)


def test_dict_of_list() raises:
    var r = from_debug[Dict[String, List[Int]]]('{"xs": [1, 2]}')
    assert_equal(len(r), 1)
    assert_equal(len(r["xs"]), 2)
    assert_equal(r["xs"][0], 1)
    assert_equal(r["xs"][1], 2)


def test_counter_string_keys() raises:
    var r = from_debug[Counter[String]]('{"a": 3, "b": 2}')
    assert_equal(len(r), 2)
    assert_equal(r["a"], 3)
    assert_equal(r["b"], 2)


def test_counter_int_keys() raises:
    var r = from_debug[Counter[Int]]("{1: 2, 2: 1}")
    assert_equal(len(r), 2)
    assert_equal(r[1], 2)
    assert_equal(r[2], 1)


def test_counter_empty() raises:
    var r = from_debug[Counter[String]]("{}")
    assert_equal(len(r), 0)


# A missing value in a `Counter` reads back as 0, distinguishing it from a
# present zero count and confirming only the listed keys were inserted.
def test_counter_absent_key_is_zero() raises:
    var r = from_debug[Counter[String]]('{"a": 5}')
    assert_equal(len(r), 1)
    assert_equal(r["a"], 5)
    assert_equal(r["missing"], 0)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
