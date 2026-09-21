from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from std.utils import Variant
from _json_format import from_json, to_json, JsonValue, JsonDeserializer
from emberserde.deserialize import (
    Deserializable,
    Deserializer,
    SelfDescribingDeserializer,
)
from emberserde.error import DerErrorKind, DeserializationError
from emberserde.field import Rename
from emberserde.struct_modifiers import (
    RenameAll,
    RenamePolicy,
    DenyUnknownFields,
)


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


@fieldwise_init
struct Record(Copyable, Defaultable, Movable):
    var name: String
    var note: Optional[Int64]

    def __init__(out self):
        self.name = String()
        self.note = None


@fieldwise_init
struct Outer(Copyable, Defaultable, Movable):
    var label: String
    var inner: Point

    def __init__(out self):
        self.label = String()
        self.inner = Point()


@fieldwise_init
struct Strict(Copyable, DenyUnknownFields, Movable):
    var a: Int


@fieldwise_init
struct CamelRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct Renamed(Copyable, Movable):
    var keep_me: Rename[Int, String("kept")]


def test_primitives() raises:
    assert_equal(from_json[Int]("42"), 42)
    assert_equal(from_json[Int]("-7"), -7)
    assert_equal(from_json[Bool]("true"), True)
    assert_equal(from_json[Bool]("false"), False)
    assert_equal(from_json[Float64]("2.5"), 2.5)
    assert_equal(from_json[String]('"hi"'), String("hi"))


def test_string_escapes() raises:
    assert_equal(from_json[String]('"say \\"hi\\""'), String('say "hi"'))
    assert_equal(from_json[String]('"a\\\\b"'), String("a\\b"))
    assert_equal(from_json[String]('"a\\nb\\tc\\rd"'), String("a\nb\tc\rd"))


def test_unicode_string() raises:
    assert_equal(from_json[String]('"héllo 🌍"'), String("héllo 🌍"))
    # Escapes adjacent to multi-byte runs keep the runs intact.
    assert_equal(from_json[String]('"é\\né"'), String("é\né"))


def test_whitespace_tolerated() raises:
    var r = from_json[List[Int]]("  [ 1 ,\n\t2 ]  ")
    assert_equal(len(r), 2)
    assert_equal(r[0], 1)
    assert_equal(r[1], 2)


def test_seq() raises:
    var r = from_json[List[Int]]("[1,2,3]")
    assert_equal(len(r), 3)
    assert_equal(r[0], 1)
    assert_equal(r[2], 3)
    var empty = from_json[List[Int]]("[]")
    assert_equal(len(empty), 0)
    var nested = from_json[List[List[Int]]]("[[1],[],[2,3]]")
    assert_equal(len(nested), 3)
    assert_equal(nested[2][1], 3)


def test_map() raises:
    var d = from_json[Dict[String, Int]]('{"a":1,"b":2}')
    assert_equal(len(d), 2)
    assert_equal(d["a"], 1)
    assert_equal(d["b"], 2)


def test_map_int_keys_unwrap_quotes() raises:
    var d = from_json[Dict[Int, Int]]('{"1":10,"2":20}')
    assert_equal(d[1], 10)
    assert_equal(d[2], 20)


def test_struct() raises:
    var p = from_json[Point]('{"x":1,"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_nested_struct() raises:
    var o = from_json[Outer]('{"label":"l","inner":{"x":1,"y":2}}')
    assert_equal(o.label, String("l"))
    assert_equal(o.inner.x, 1)
    assert_equal(o.inner.y, 2)


# The junk value nests containers and hides a `}` inside a string, so this
# exercises `skip_json_value`'s bracket balancing and string jumping.
def test_struct_unknown_field_skipped() raises:
    var p = from_json[Point]('{"x":1,"junk":{"a":[1,{"b":"}"}]},"y":2}')
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_struct_missing_optional_fills_none() raises:
    var r = from_json[Record]('{"name":"n"}')
    assert_equal(r.name, String("n"))
    assert_false(Bool(r.note))


def test_struct_missing_required_raises() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1}')


def test_struct_duplicate_field_raises() raises:
    with assert_raises():
        _ = from_json[Point]('{"x":1,"x":2,"y":3}')


def test_deny_unknown_fields_raises() raises:
    with assert_raises(contains="Unknown field: b"):
        _ = from_json[Strict]('{"a":1,"b":2}')


def test_rename_all_matches_wire() raises:
    var r = from_json[CamelRec]('{"firstName":1,"age":2}')
    assert_equal(r.first_name, 1)
    assert_equal(r.age, 2)


def test_field_rename_matches_wire() raises:
    var r = from_json[Renamed]('{"kept":2}')
    assert_equal(r.keep_me.value, 2)


def test_tuple() raises:
    var t = from_json[Tuple[Int, String]]('[1,"hi"]')
    assert_equal(t[0], 1)
    assert_equal(t[1], String("hi"))


def test_optional() raises:
    var some = from_json[Optional[Int64]]("5")
    assert_true(Bool(some))
    assert_equal(some.value(), Int64(5))
    var none = from_json[Optional[Int64]]("null")
    assert_false(Bool(none))


@fieldwise_init
struct ByteBuf(Deserializable, Movable):
    var data: List[Byte]

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_bytes())


def test_bytes() raises:
    var r = from_json[ByteBuf]("[1,2,255]")
    assert_equal(len(r.data), 3)
    assert_equal(r.data[0], 1)
    assert_equal(r.data[2], 255)


def test_enum_int_arm() raises:
    var r = from_json[Variant[Int64, String]]('{"SIMD[DType.int64, 1]":5}')
    assert_true(r.isa[Int64]())
    assert_equal(r.unsafe_get[Int64](), Int64(5))


def test_enum_string_arm() raises:
    var r = from_json[Variant[Int64, String]]('{"String":"hi"}')
    assert_true(r.isa[String]())
    assert_equal(r.unsafe_get[String](), String("hi"))


def test_enum_unknown_arm_raises() raises:
    with assert_raises():
        _ = from_json[Variant[Int64, String]]('{"Bogus":1}')


def test_malformed_raises() raises:
    with assert_raises():
        _ = from_json[String]('"unterminated')
    with assert_raises():
        _ = from_json[Bool]("tru")
    with assert_raises():
        _ = from_json[Int]('"not a number"')
    with assert_raises():
        _ = from_json[List[Int]]("[1,2")


def test_trailing_garbage_raises() raises:
    with assert_raises():
        _ = from_json[Int]("42abc")
    with assert_raises():
        _ = from_json[Bool]("truex")


def test_type_mismatch_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Int]('"str"')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.TypeMismatch)


def test_numeric_narrowing_rejected() raises:
    with assert_raises():
        _ = from_json[UInt8]("300")
    with assert_raises():
        _ = from_json[UInt8]("-5")
    assert_equal(from_json[UInt8]("255"), UInt8(255))


def test_invalid_number_kind() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[Int]("1.2.3")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.InvalidValue)


def test_wrong_shape_kinds() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_json[String]("42")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.TypeMismatch)

    kind = DerErrorKind.Custom
    try:
        _ = from_json[List[Int]]('"x"')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.TypeMismatch)

    kind = DerErrorKind.Custom
    try:
        _ = from_json[String]('"unterminated')
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.InvalidValue)


def test_any_null() raises:
    assert_true(from_json[JsonValue]("null").is_null())


def test_any_bool() raises:
    var v = from_json[JsonValue]("true")
    assert_true(v.is_bool())
    assert_true(v.as_bool())


def test_any_int() raises:
    var v = from_json[JsonValue]("42")
    assert_true(v.is_int())
    assert_equal(v.as_int(), Int64(42))


def test_any_float() raises:
    var v = from_json[JsonValue]("2.5")
    assert_true(v.is_float())
    assert_equal(v.as_float(), Float64(2.5))


def test_any_number_forms() raises:
    var neg_int = from_json[JsonValue]("-5")
    assert_true(neg_int.is_int())
    assert_equal(neg_int.as_int(), Int64(-5))

    var exp_float = from_json[JsonValue]("1e3")
    assert_true(exp_float.is_float())
    assert_equal(exp_float.as_float(), Float64(1000.0))

    var neg_float = from_json[JsonValue]("-1.5")
    assert_true(neg_float.is_float())
    assert_equal(neg_float.as_float(), Float64(-1.5))


def test_any_string() raises:
    var v = from_json[JsonValue]('"hi"')
    assert_true(v.is_string())
    assert_equal(v.as_string(), String("hi"))


def test_any_array() raises:
    var v = from_json[JsonValue]('[1,"two",null]')
    assert_true(v.is_array())
    var arr = v.as_array()
    assert_equal(len(arr), 3)
    assert_equal(arr[0].as_int(), Int64(1))
    assert_equal(arr[1].as_string(), String("two"))
    assert_true(arr[2].is_null())


def test_any_nested_object() raises:
    var v = from_json[JsonValue]('{"a":{"b":[1,true]}}')
    assert_true(v.is_object())
    var inner = v.as_object()["a"].as_object()["b"].as_array()
    assert_equal(inner[0].as_int(), Int64(1))
    assert_true(inner[1].as_bool())


def test_any_malformed_raises() raises:
    with assert_raises():
        _ = from_json[JsonValue]("@")


# Parse → re-serialize → string equality against the hand-written literal:
# insertion-ordered `Dict` keeps object key order stable, so the compact
# canonical form round-trips exactly.
def test_round_trip_through_json_value() raises:
    var src = String('{"a":[1,2.5,true,null,"s\\"x"],"b":{"c":false}}')
    var v = from_json[JsonValue](src.copy())
    assert_equal(to_json(v), src)


def test_conformance() raises:
    assert_true(
        conforms_to(JsonDeserializer[MutAnyOrigin], SelfDescribingDeserializer)
    )
    assert_true(conforms_to(JsonDeserializer[MutAnyOrigin], Deserializer))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
