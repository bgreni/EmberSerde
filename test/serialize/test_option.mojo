# Serialize both arms of `Optional` through the debug format.
#
# The framework's `Optional.serialize` impl renders the contained value
# transparently when present, and `serialize_none` ("None") when empty.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


def test_some() raises:
    var o = Optional(Int64(5))
    assert_equal(debug_string(o), "5")


def test_none() raises:
    var o = Optional[Int64](None)
    assert_equal(debug_string(o), "None")


def test_some_string() raises:
    var o = Optional(String("hi"))
    assert_equal(debug_string(o), '"hi"')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
