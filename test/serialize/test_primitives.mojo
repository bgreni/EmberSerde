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


def test_simd() raises:
    # Multi-lane SIMD serializes as a tuple (lane count is comptime, no length
    # token), so the debug format renders it with parens.
    assert_equal(debug_string(SIMD[DType.int32, 4](1, 2, 3, 4)), "(1, 2, 3, 4)")
    assert_equal(
        debug_string(SIMD[DType.float64, 2](1.5, -2.25)), "(1.5, -2.25)"
    )


def test_string() raises:
    assert_equal(debug_string(String("hello")), '"hello"')
    assert_equal(debug_string(String("")), '""')


# A literal-typed field stays `IntLiteral`/`FloatLiteral` (it does not
# materialize to `Int`/`Float64`), so serializing it through reflection
# dispatches to the literal impls.
struct Foo(Copyable, Defaultable):
    var x: IntLiteral[(42).value]

    def __init__(out self):
        self.x = {}


struct Bar(Copyable, Defaultable):
    var x: FloatLiteral[(3.14).value]

    def __init__(out self):
        self.x = {}


def test_literals() raises:
    assert_equal(debug_string(Foo()), "test_primitives.Foo { x: 42 }")
    assert_equal(debug_string(Bar()), "test_primitives.Bar { x: 3.14 }")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
