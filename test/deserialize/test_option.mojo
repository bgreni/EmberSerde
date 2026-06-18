from std.testing import assert_equal, assert_true, assert_false, TestSuite
from _debug_format import from_debug


def test_some() raises:
    var v = from_debug[Optional[Int64]]("Some(5)")
    assert_true(Bool(v))
    assert_equal(v.value(), Int64(5))


def test_none() raises:
    var v = from_debug[Optional[Int64]]("None")
    assert_false(Bool(v))


def test_some_string() raises:
    var v = from_debug[Optional[String]]('Some("hi")')
    assert_true(Bool(v))
    assert_equal(v.value(), String("hi"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
