# Round-trip both arms of `Optional` through the debug format.
# The counterpart of `test_option.mojo`.

from std.testing import assert_equal, assert_true, assert_false, TestSuite
from _debug_format import debug_string, from_debug


def test_some() raises:
    var o = Optional(Int64(5))
    var v = from_debug[Optional[Int64]](debug_string(o))
    assert_true(Bool(v))
    assert_equal(v.value(), Int64(5))


def test_none() raises:
    var o = Optional[Int64](None)
    var v = from_debug[Optional[Int64]](debug_string(o))
    assert_false(Bool(v))


def test_some_string() raises:
    var o = Optional(String("hi"))
    var v = from_debug[Optional[String]](debug_string(o))
    assert_true(Bool(v))
    assert_equal(v.value(), String("hi"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
