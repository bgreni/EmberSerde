# Deserialize `Dict` from hand-written debug-format literals via the
# `MapDerState` framing. The counterpart of `serialize/test_map.mojo`. Inputs
# are spelled out explicitly rather than produced by the serializer.

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


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
