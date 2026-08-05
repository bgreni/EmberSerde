from std.utils import Variant
from std.testing import assert_equal, assert_true, assert_raises, TestSuite
from _debug_format import from_debug
from _token_format import from_tokens
from emberserde.struct_modifiers import ArmName


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


# Hand-written wire literals (not serializer output): the arm tag is the
# canonical type name, so a scalar arm is tagged `SIMD[DType.int64, 1]`.
def test_variant_int_arm() raises:
    var r = from_debug[Variant[Int64, String]]("SIMD[DType.int64, 1](5)")
    assert_true(r.isa[Int64]())
    assert_equal(r.unsafe_get[Int64](), Int64(5))


def test_variant_string_arm() raises:
    var r = from_debug[Variant[Int64, String]]('String("hi")')
    assert_true(r.isa[String]())
    assert_equal(r.unsafe_get[String](), String("hi"))


def test_variant_struct_arm() raises:
    var r = from_debug[Variant[Int64, Point]](
        "test_enum.Point(test_enum.Point { x: 1, y: 2 })"
    )
    assert_true(r.isa[Point]())
    assert_equal(r.unsafe_get[Point]().x, 1)
    assert_equal(r.unsafe_get[Point]().y, 2)


def test_unknown_variant_raises() raises:
    with assert_raises():
        _ = from_debug[Variant[Int64, String]]("Bogus(1)")


@fieldwise_init
struct Named(ArmName, Copyable, Defaultable, Movable):
    comptime serde_arm_name: StaticString = "named"
    var n: Int

    def __init__(out self):
        self.n = 0


def test_variant_arm_name_binds_tag() raises:
    # The declared `ArmName` is the tag; the canonical type name no longer
    # matches.
    var r = from_debug[Variant[Int64, Named]]("named(N { n: 3 })")
    assert_true(r.isa[Named]())
    assert_equal(r.unsafe_get[Named]().n, 3)
    with assert_raises():
        _ = from_debug[Variant[Int64, Named]]("test_enum.Named(N { n: 3 })")


# Non-self-describing wire: hand-written `[index, payload]` token lists.
def test_variant_tokens_first_arm() raises:
    var r = from_tokens[Variant[Int64, String]](["0", "5"])
    assert_true(r.isa[Int64]())
    assert_equal(r.unsafe_get[Int64](), Int64(5))


def test_variant_tokens_second_arm() raises:
    var r = from_tokens[Variant[Int64, String]](["1", "hi"])
    assert_true(r.isa[String]())
    assert_equal(r.unsafe_get[String](), String("hi"))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
