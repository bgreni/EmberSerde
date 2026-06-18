from std.testing import assert_equal, TestSuite, assert_raises
from _debug_format import from_debug
from emberserde.deserialize import DeserializationError


def test_bool() raises:
    assert_equal(from_debug[Bool]("true"), True)
    assert_equal(from_debug[Bool]("false"), False)


def test_signed_ints() raises:
    assert_equal(from_debug[Int8]("-8"), Int8(-8))
    assert_equal(from_debug[Int16]("-16"), Int16(-16))
    assert_equal(from_debug[Int32]("-32"), Int32(-32))
    assert_equal(from_debug[Int64]("-64"), Int64(-64))
    assert_equal(from_debug[Int]("42"), 42)  # machine Int


def test_unsigned_ints() raises:
    assert_equal(from_debug[UInt8]("8"), UInt8(8))
    assert_equal(from_debug[UInt16]("16"), UInt16(16))
    assert_equal(from_debug[UInt32]("32"), UInt32(32))
    assert_equal(from_debug[UInt64]("64"), UInt64(64))


def test_floats() raises:
    assert_equal(from_debug[Float32]("1.5"), Float32(1.5))
    assert_equal(from_debug[Float64]("-2.25"), Float64(-2.25))


def test_simd() raises:
    assert_equal(
        from_debug[SIMD[DType.int32, 4]]("(1, 2, 3, 4)"),
        SIMD[DType.int32, 4](1, 2, 3, 4),
    )
    assert_equal(
        from_debug[SIMD[DType.float64, 2]]("(1.5, -2.25)"),
        SIMD[DType.float64, 2](1.5, -2.25),
    )


def test_string() raises:
    assert_equal(from_debug[String]('"hello"'), String("hello"))
    assert_equal(from_debug[String]('""'), String(""))


struct Foo(Copyable, Defaultable):
    var x: IntLiteral[(42).value]

    def __init__(out self):
        self.x = {}


struct Bar(Copyable, Defaultable):
    var x: FloatLiteral[(3.14).value]

    def __init__(out self):
        self.x = {}


def test_literals() raises:
    assert_equal(from_debug[Foo]("Foo { x: 42 }").x, Foo().x)

    with assert_raises():
        _ = from_debug[Foo]("Foo { x: 43 }")

    assert_equal(from_debug[Bar]("Bar { x: 3.14 }").x, Bar().x)

    with assert_raises():
        _ = from_debug[Bar]("Bar { x: 2.71 }")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
