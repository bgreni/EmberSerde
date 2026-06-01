# Serialize each primitive through the debug format and assert its rendering.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


def test_bool() raises:
    assert_equal(debug_string(True), "true")
    assert_equal(debug_string(False), "false")


def test_signed_ints() raises:
    assert_equal(debug_string(Int8(-8)), "-8")
    assert_equal(debug_string(Int16(-16)), "-16")
    assert_equal(debug_string(Int32(-32)), "-32")
    assert_equal(debug_string(Int64(-64)), "-64")
    assert_equal(debug_string(42), "42")  # machine Int


def test_unsigned_ints() raises:
    assert_equal(debug_string(UInt8(8)), "8")
    assert_equal(debug_string(UInt16(16)), "16")
    assert_equal(debug_string(UInt32(32)), "32")
    assert_equal(debug_string(UInt64(64)), "64")


def test_floats() raises:
    assert_equal(debug_string(Float32(1.5)), "1.5")
    assert_equal(debug_string(Float64(-2.25)), "-2.25")


def test_string() raises:
    assert_equal(debug_string(String("hello")), '"hello"')
    assert_equal(debug_string(String("")), '""')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
