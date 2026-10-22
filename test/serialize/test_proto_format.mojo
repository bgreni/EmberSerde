from std.testing import assert_equal, assert_true, TestSuite
from std.utils import Variant
from _proto_format import (
    Fixed,
    ProtoOneof,
    ProtoTag,
    ZigZag,
    from_proto,
    to_proto,
    wire,
)
from emberserde.field import Default, SerializeWith, Skip
from emberserde.serialize import Serializable, Serializer
from emberserde.error import SerializationError


@fieldwise_init
struct Test1(Movable):
    var a: Int32
    var b: String


@fieldwise_init
struct Test5(Movable):
    @__annotation(ProtoTag(4))
    var d: List[Int32]


def test_encoding_guide_examples() raises:
    assert_equal(
        to_proto(Test1(150, "testing")),
        wire("08 96 01  12 07 74 65 73 74 69 6e 67"),
    )
    assert_equal(
        to_proto(Test5([3, 270, 86942])), wire("22 06 03 8e 02 9e a7 05")
    )


@fieldwise_init
struct Scalars(Movable):
    var i32: Int32
    var i64: Int64
    var u32: UInt32
    var u64: UInt64
    var b: Bool
    var n: Int


def test_varint_scalars() raises:
    assert_equal(
        to_proto(Scalars(-1, 300, 150, UInt64.MAX, True, -2)),
        wire(
            "08 ff ff ff ff ff ff ff ff ff 01  10 ac 02  18 96 01"
            "  20 ff ff ff ff ff ff ff ff ff 01  28 01"
            "  30 fe ff ff ff ff ff ff ff ff 01"
        ),
    )


@fieldwise_init
struct Encodings(Movable):
    @__annotation(ZigZag())
    var s32: Int32

    @__annotation(ZigZag())
    var s64: Int64

    @__annotation(Fixed())
    var f32: UInt32

    @__annotation(Fixed())
    var sf64: Int64
    var fl: Float32
    var d: Float64


def test_zigzag_fixed_and_floats() raises:
    assert_equal(
        to_proto(Encodings(-1, -64, 1, -2, 1.5, -0.5)),
        wire(
            "08 01  10 7f  1d 01 00 00 00  21 fe ff ff ff ff ff ff ff"
            "  2d 00 00 c0 3f  31 00 00 00 00 00 00 e0 bf"
        ),
    )


def test_negative_zero_is_not_the_default() raises:
    assert_equal(
        to_proto(Encodings(0, 0, 0, 0, 0.0, -0.0)),
        wire("31 00 00 00 00 00 00 00 80"),
    )


@fieldwise_init
struct Inner(Copyable, Movable):
    var a: Int64
    var b: Int64


@fieldwise_init
struct Everything(Movable):
    var n: Int64
    var s: String
    var xs: List[Int32]
    var m: Inner
    var opt: Optional[Int32]


def test_implicit_presence_omits_zero_values() raises:
    # Only the message field is written, and it is written empty.
    assert_equal(
        to_proto(Everything(0, "", [], Inner(0, 0), None)), wire("22 00")
    )


@fieldwise_init
struct Presence(Movable):
    var x: Optional[Int32]
    var m: Optional[Inner]


def test_explicit_presence_writes_zero_values() raises:
    assert_equal(
        to_proto(Presence(Int32(0), Inner(0, 0))), wire("08 00  12 00")
    )
    assert_equal(to_proto(Presence(None, None)), wire(""))


def _redact(s: String) raises -> String:
    return "***"


@fieldwise_init
struct Annotated(Movable):
    @__annotation(Default(Int32(7)))
    var level: Int32

    @__annotation(Skip())
    var cache: Int32

    @__annotation(SerializeWith(_redact))
    var secret: String


def test_framework_field_annotations() raises:
    # A Default-carrying field reads back as its Default when absent, so a
    # zero is written; the skipped field is not.
    assert_equal(to_proto(Annotated(0, 5, "pw")), wire("08 00  1a 03 2a 2a 2a"))


@fieldwise_init
struct Lists(Movable):
    var xs: List[Int32]

    @__annotation(ZigZag())
    var zs: List[Int32]
    var fs: List[Float32]
    var bs: List[Bool]
    var names: List[String]


def test_scalar_lists_are_packed() raises:
    assert_equal(
        to_proto(Lists([1, 2], [-1, 1], [1.5], [True, False], ["a", ""])),
        wire(
            "0a 02 01 02  12 02 01 02  1a 04 00 00 c0 3f  22 02 01 00"
            "  2a 01 61  2a 00"
        ),
    )
    assert_equal(to_proto(Lists([], [], [], [], [])), wire(""))


@fieldwise_init
struct Repeated(Movable):
    var items: List[Inner]
    var name: String


def test_repeated_messages() raises:
    assert_equal(
        to_proto(Repeated([Inner(1, 0), Inner(0, 2)], "x")),
        wire("0a 02 08 01  0a 02 10 02  12 01 78"),
    )


@fieldwise_init
struct Maps(Movable):
    var counts: Dict[String, Int64]
    var byid: Dict[Int32, Inner]


def test_maps_are_entry_messages() raises:
    var counts: Dict[String, Int64] = {"a": 1, "z": 0}
    var byid: Dict[Int32, Inner] = {7: Inner(9, 0)}
    # Entries write their key and value even when zero.
    assert_equal(
        to_proto(Maps(counts^, byid^)),
        wire(
            "0a 05 0a 01 61 10 01  0a 05 0a 01 7a 10 00"
            "  12 06 08 07 12 02 08 09"
        ),
    )


@fieldwise_init
struct Circle(Copyable, Defaultable, Movable):
    var r: Int32
    var label: String

    def __init__(out self):
        self.r = 0
        self.label = String()


@fieldwise_init
struct Square(Copyable, Movable):
    var side: Int32


@fieldwise_init
struct Drawing(Movable):
    var id: Int32

    @__annotation(ProtoOneof[4, 9]())
    var shape: Optional[Variant[Circle, Square]]


def test_oneof_members_are_fields_of_the_parent() raises:
    assert_equal(
        to_proto(Drawing(1, Variant[Circle, Square](Circle(2, "c")))),
        wire("08 01  22 05 08 02 12 01 63"),
    )
    # A member is written even when it holds only zeros.
    assert_equal(
        to_proto(Drawing(1, Variant[Circle, Square](Square(0)))),
        wire("08 01  4a 00"),
    )
    assert_equal(to_proto(Drawing(1, None)), wire("08 01"))


@fieldwise_init
struct Boxed(Movable):
    var v: Variant[Int64, String]


def test_variant_without_oneof_is_boxed() raises:
    assert_equal(
        to_proto(Boxed(Variant[Int64, String](String("hi")))),
        wire("0a 04 12 02 68 69"),
    )
    assert_equal(
        to_proto(Boxed(Variant[Int64, String](Int64(0)))), wire("0a 02 08 00")
    )


@fieldwise_init
struct Nested(Movable):
    var grid: List[List[Int32]]
    var maybes: List[Optional[Int32]]


def test_nested_containers_are_boxed() raises:
    var grid: List[List[Int32]] = [[1, 2], [3], []]
    var maybes: List[Optional[Int32]] = [Int32(0), None]
    assert_equal(
        to_proto(Nested(grid^, maybes^)),
        wire("0a 04 0a 02 01 02  0a 03 0a 01 03  0a 00  12 02 08 00  12 00"),
    )


@fieldwise_init
struct Tuples(Movable):
    var pair: Tuple[Int32, String]
    var arr: Array[Int32, 3]


def test_tuples_are_messages() raises:
    var arr = Array[Int32, 3](fill=0)
    arr[0] = 1
    arr[2] = 3
    assert_equal(
        to_proto(Tuples((Int32(5), String("x")), arr^)),
        wire("0a 05 08 05 12 01 78  12 04 08 01 18 03"),
    )


def test_root_list_is_boxed() raises:
    var xs: List[Int32] = [1, 2, 3]
    assert_equal(to_proto(xs), wire("0a 03 01 02 03"))


@fieldwise_init
struct ByteBuf(Movable, Serializable):
    var data: List[Byte]

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bytes(Span(self.data))


@fieldwise_init
struct Blob(Movable):
    var s: String
    var raw: ByteBuf


def test_strings_and_bytes() raises:
    assert_equal(
        to_proto(Blob("héllo", ByteBuf([0, 255]))),
        wire("0a 06 68 c3 a9 6c 6c 6f  12 02 00 ff"),
    )


@fieldwise_init
struct Tagged(Movable):
    @__annotation(ProtoTag(100))
    var far: Int32

    @__annotation(ProtoTag(2))
    var near: Int32


# Written in field-number order, as the reference serializer does,
# whatever the declaration order.
def test_fields_are_written_in_number_order() raises:
    assert_equal(to_proto(Tagged(1, 2)), wire("10 02  a0 06 01"))


@fieldwise_init
struct Rich(Defaultable, Movable):
    var id: Int32
    var name: String
    var tags: List[String]
    var scores: Dict[String, Float64]
    var inner: Optional[Inner]

    @__annotation(ProtoOneof[10, 11]())
    var shape: Optional[Variant[Circle, Square]]
    var grid: List[List[Int32]]

    @__annotation(ZigZag())
    var deltas: List[Int64]
    var flag: Bool

    def __init__(out self):
        self.id = 0
        self.name = String()
        self.tags = []
        self.scores = {}
        self.inner = None
        self.shape = None
        self.grid = []
        self.deltas = []
        self.flag = False


def test_round_trip() raises:
    var r = Rich()
    r.id = -7
    r.name = "rich"
    r.tags = ["a", "", "c"]
    r.scores = {"x": 1.5, "y": -2.0}
    r.inner = Inner(3, 0)
    r.shape = Variant[Circle, Square](Circle(4, "o"))
    r.grid = [[1], [], [2, 3]]
    r.deltas = [-1, 0, Int64.MAX, Int64.MIN]
    r.flag = True
    var back = from_proto[Rich](to_proto(r))
    assert_equal(back.id, -7)
    assert_equal(back.name, "rich")
    assert_equal(back.tags, ["a", "", "c"])
    assert_equal(back.scores["x"], 1.5)
    assert_equal(back.scores["y"], -2.0)
    assert_equal(back.inner.value().a, 3)
    assert_equal(back.shape.value()[Circle].label, "o")
    assert_equal(len(back.grid), 3)
    assert_equal(back.grid[2], [2, 3])
    assert_equal(back.deltas, [-1, 0, Int64.MAX, Int64.MIN])
    assert_true(back.flag)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
