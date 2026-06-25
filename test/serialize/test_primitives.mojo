from std.collections.string import Codepoint
from std.complex import ComplexSIMD
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


# Non-owning string views route through `serialize_string`, so they render
# identically to a `String`. Serialize-only: there is nothing to borrow from
# on the way back, same precedent as `Pointer`.
def test_string_slice() raises:
    var s = String("hello")
    assert_equal(debug_string(StringSlice(s)), '"hello"')


def test_static_string() raises:
    assert_equal(debug_string(StaticString("hi")), '"hi"')


# A `Codepoint` rides the wire as its `u32` scalar value.
def test_codepoint() raises:
    assert_equal(debug_string(Codepoint.ord("a")), "97")
    assert_equal(debug_string(Codepoint.ord("€")), "8364")


# `ComplexSIMD` rides the wire as a 2-element `(re, im)` tuple. A scalar
# (`size == 1`) renders each part as a number.
def test_complex_scalar() raises:
    assert_equal(
        debug_string(ComplexSIMD[DType.float64, 1](1.5, -2.25)), "(1.5, -2.25)"
    )


# A vector `ComplexSIMD` (`size > 1`) renders one `(re, im)` pair per lane,
# interleaved — not the `re`/`im` SIMD split.
def test_complex_vector() raises:
    var c = ComplexSIMD[DType.int32, 2](
        SIMD[DType.int32, 2](1, 2), SIMD[DType.int32, 2](3, 4)
    )
    assert_equal(debug_string(c), "((1, 3), (2, 4))")


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
