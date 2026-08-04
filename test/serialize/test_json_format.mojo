from std.testing import assert_equal, TestSuite
from std.utils import Variant
from _json_format import to_json
from emberserde.struct_modifiers import RenameAll, RenamePolicy


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Nested(Copyable, Movable):
    var label: String
    var point: Point
    var note: Optional[Int64]


@fieldwise_init
struct CamelRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var age: Int


def test_primitives() raises:
    assert_equal(to_json(Int(42)), "42")
    assert_equal(to_json(Int(-7)), "-7")
    assert_equal(to_json(True), "true")
    assert_equal(to_json(False), "false")
    assert_equal(to_json(Float64(2.5)), "2.5")
    assert_equal(to_json(String("hi")), '"hi"')


def test_string_escapes() raises:
    assert_equal(to_json(String('say "hi"')), '"say \\"hi\\""')
    assert_equal(to_json(String("a\\b")), '"a\\\\b"')
    assert_equal(to_json(String("a\nb\tc\rd")), '"a\\nb\\tc\\rd"')


def test_seq() raises:
    var l: List[Int] = [1, 2, 3]
    assert_equal(to_json(l), "[1,2,3]")
    var empty = List[Int]()
    assert_equal(to_json(empty), "[]")
    var nested: List[List[Int]] = [[1], [], [2, 3]]
    assert_equal(to_json(nested), "[[1],[],[2,3]]")


def test_map() raises:
    var d: Dict[String, Int] = {"a": 1, "b": 2}
    assert_equal(to_json(d), '{"a":1,"b":2}')
    var empty = Dict[String, Int]()
    assert_equal(to_json(empty), "{}")


def test_map_non_string_keys_are_stringified() raises:
    var d = Dict[Int, Int]()
    d[1] = 10
    d[2] = 20
    assert_equal(to_json(d), '{"1":10,"2":20}')


def test_struct() raises:
    assert_equal(to_json(Point(x=1, y=2)), '{"x":1,"y":2}')
    var some = Nested(
        label=String("n"), point=Point(x=1, y=2), note=Optional[Int64](5)
    )
    assert_equal(to_json(some), '{"label":"n","point":{"x":1,"y":2},"note":5}')
    var none = Nested(label=String("m"), point=Point(x=0, y=0), note=None)
    assert_equal(
        to_json(none), '{"label":"m","point":{"x":0,"y":0},"note":null}'
    )


def test_struct_rename_all() raises:
    assert_equal(
        to_json(CamelRec(first_name=1, age=2)), '{"firstName":1,"age":2}'
    )


def test_optional() raises:
    assert_equal(to_json(Optional[Int64](5)), "5")
    assert_equal(to_json(Optional[Int64]()), "null")


def test_tuple() raises:
    assert_equal(to_json(Tuple(Int(1), String("hi"))), '[1,"hi"]')


def test_enum() raises:
    var i = Variant[Int64, String](Int64(5))
    assert_equal(to_json(i), '{"SIMD[DType.int64, 1]":5}')
    var s = Variant[Int64, String](String("hi"))
    assert_equal(to_json(s), '{"String":"hi"}')


def test_bytes() raises:
    var data: List[Byte] = [1, 2, 255]
    assert_equal(to_json(Span(data)), "[1,2,255]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
