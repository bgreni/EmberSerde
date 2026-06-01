# Round-trip each primitive: serialize to the debug format, then deserialize
# back and assert equality. The deserialize-side counterpart of
# `test_primitives.mojo`.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string, from_debug


def test_bool() raises:
    assert_equal(from_debug[Bool](debug_string(True)), True)
    assert_equal(from_debug[Bool](debug_string(False)), False)


def test_signed_ints() raises:
    assert_equal(from_debug[Int8](debug_string(Int8(-8))), Int8(-8))
    assert_equal(from_debug[Int16](debug_string(Int16(-16))), Int16(-16))
    assert_equal(from_debug[Int32](debug_string(Int32(-32))), Int32(-32))
    assert_equal(from_debug[Int64](debug_string(Int64(-64))), Int64(-64))
    assert_equal(from_debug[Int](debug_string(42)), 42)  # machine Int


def test_unsigned_ints() raises:
    assert_equal(from_debug[UInt8](debug_string(UInt8(8))), UInt8(8))
    assert_equal(from_debug[UInt16](debug_string(UInt16(16))), UInt16(16))
    assert_equal(from_debug[UInt32](debug_string(UInt32(32))), UInt32(32))
    assert_equal(from_debug[UInt64](debug_string(UInt64(64))), UInt64(64))


def test_floats() raises:
    assert_equal(from_debug[Float32](debug_string(Float32(1.5))), Float32(1.5))
    assert_equal(
        from_debug[Float64](debug_string(Float64(-2.25))), Float64(-2.25)
    )


def test_string() raises:
    assert_equal(
        from_debug[String](debug_string(String("hello"))), String("hello")
    )
    assert_equal(from_debug[String](debug_string(String(""))), String(""))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
