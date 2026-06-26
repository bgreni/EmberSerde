from std.utils import Variant
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string
from _token_format import to_tokens


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Holder(Copyable, Movable):
    var tag: Variant[Int64, String]


# The tag is the arm's canonical type name from `reflect[T].name()`, so a scalar
# renders as `SIMD[DType.int64, 1]`, not the `Int64` alias.
def test_variant_int_arm() raises:
    var v = Variant[Int64, String](Int64(5))
    assert_equal(debug_string(v), "SIMD[DType.int64, 1](5)")


def test_variant_string_arm() raises:
    var v = Variant[Int64, String](String("hi"))
    assert_equal(debug_string(v), 'String("hi")')


# A struct arm: the enum tag and the struct's own name both appear (both
# module-qualified), which is redundant but round-trips cleanly.
def test_variant_struct_arm() raises:
    var v = Variant[Int64, Point](Point(1, 2))
    assert_equal(
        debug_string(v),
        "test_enum.Point(test_enum.Point { x: 1, y: 2 })",
    )


def test_struct_with_variant_field() raises:
    assert_equal(
        debug_string(Holder(Variant[Int64, String](Int64(5)))),
        "test_enum.Holder { tag: SIMD[DType.int64, 1](5) }",
    )


# The non-self-describing token format writes the arm *index* (not the name)
# followed by the payload.
def test_variant_tokens_first_arm() raises:
    var toks = to_tokens(Variant[Int64, String](Int64(5)))
    assert_equal(len(toks), 2)
    assert_equal(toks[0], "0")
    assert_equal(toks[1], "5")


def test_variant_tokens_second_arm() raises:
    var toks = to_tokens(Variant[Int64, String](String("hi")))
    assert_equal(len(toks), 2)
    assert_equal(toks[0], "1")
    assert_equal(toks[1], "hi")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
