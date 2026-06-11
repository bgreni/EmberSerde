# Serialize `Dict` through the debug format via the `MapSerState` framing.
# Mojo's `Dict` preserves insertion order, so the rendered strings are
# deterministic.

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
