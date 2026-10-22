from std.testing import (
    assert_equal,
    assert_false,
    assert_true,
    TestSuite,
)
from std.utils import Variant
from _proto_format import (
    Fixed,
    ProtoOneof,
    ProtoTag,
    UnknownFields,
    ZigZag,
    from_proto,
    to_proto,
    wire,
)
from emberserde.deserialize import Deserializable, Deserializer, deserialize
from emberserde.error import DerErrorKind, DeserializationError
from emberserde.field import Default, Skip, Transform
from emberserde.struct_modifiers import DenyUnknownFields
from emberserde.validate import Validate


@fieldwise_init
struct Failure(Copyable, Movable):
    var kind: DerErrorKind
    var path: String


def fail_of[T: Deinitable](hex: StringSlice) raises -> Failure:
    var bytes = wire(hex)
    try:
        _ = from_proto[T](bytes^)
    except e:
        return Failure(e.kind, e.path)
    raise Error("expected the read to fail")


@fieldwise_init
struct Scalars(Movable):
    var i32: Int32
    var i64: Int64
    var u32: UInt32
    var u64: UInt64
    var b: Bool
    var n: Int


def test_varint_scalars() raises:
    # i32 = -1 (sign-extended to 10 bytes), i64 = 300, u32 = 150,
    # u64 = 2^64 - 1, b = true, n = -2
    var s = from_proto[Scalars](
        wire(
            "08 ff ff ff ff ff ff ff ff ff 01  10 ac 02  18 96 01"
            "  20 ff ff ff ff ff ff ff ff ff 01  28 01"
            "  30 fe ff ff ff ff ff ff ff ff 01"
        )
    )
    assert_equal(s.i32, -1)
    assert_equal(s.i64, 300)
    assert_equal(s.u32, 150)
    assert_equal(s.u64, UInt64.MAX)
    assert_true(s.b)
    assert_equal(s.n, -2)


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
    var e = from_proto[Encodings](
        wire(
            "08 01  10 7f  1d 01 00 00 00  21 fe ff ff ff ff ff ff ff"
            "  2d 00 00 c0 3f  31 00 00 00 00 00 00 e0 bf"
        )
    )
    assert_equal(e.s32, -1)
    assert_equal(e.s64, -64)
    assert_equal(e.f32, 1)
    assert_equal(e.sf64, -2)
    assert_equal(e.fl, 1.5)
    assert_equal(e.d, -0.5)


@fieldwise_init
struct ByteBuf(Deserializable, Movable):
    var data: List[Byte]

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_bytes())


@fieldwise_init
struct Blob(Defaultable, Movable):
    var s: String
    var raw: ByteBuf

    def __init__(out self):
        self.s = String()
        self.raw = ByteBuf([])


def test_strings_and_bytes() raises:
    var b = from_proto[Blob](wire("0a 06 68 c3 a9 6c 6c 6f  12 02 00 ff"))
    assert_equal(b.s, "héllo")
    assert_equal(b.raw.data, [0, 255])


def test_invalid_utf8_rejected() raises:
    assert_equal(fail_of[Blob]("0a 01 ff").kind, DerErrorKind.InvalidValue)


# The encoding guide's own examples: field 1 = 150, field 2 = "testing".
@fieldwise_init
struct Test1(Defaultable, Movable):
    var a: Int32
    var b: String

    def __init__(out self):
        self.a = 0
        self.b = String()


def test_encoding_guide_examples() raises:
    var t = from_proto[Test1](wire("08 96 01  12 07 74 65 73 74 69 6e 67"))
    assert_equal(t.a, 150)
    assert_equal(t.b, "testing")


@fieldwise_init
struct Inner(Copyable, Movable):
    var a: Int64
    var b: Int64


@fieldwise_init
struct Outer(Movable):
    var m: Inner


@fieldwise_init
struct Everything(Defaultable, Movable):
    var n: Int64
    var s: String
    var xs: List[Int32]
    var m: Inner
    var opt: Optional[Int32]

    def __init__(out self):
        self.n = 0
        self.s = String()
        self.xs = []
        self.m = Inner(0, 0)
        self.opt = None


def test_absent_fields_read_as_zero() raises:
    var e = from_proto[Everything](wire(""))
    assert_equal(e.n, 0)
    assert_equal(e.s, "")
    assert_equal(len(e.xs), 0)
    assert_equal(e.m.a, 0)
    assert_false(Bool(e.opt))


def test_last_scalar_wins() raises:
    assert_equal(from_proto[Test1](wire("08 01  08 02  08 03")).a, 3)


# APPROACH_2_VS_3.md's worked example, m{a:5} m{b:7} m{a:0}: the reference
# parser gives {a: 0, b: 7}, where merging decoded values gives {a: 5, b: 7}.
def test_message_occurrences_merge() raises:
    var o = from_proto[Outer](wire("0a 02 08 05  0a 02 10 07  0a 02 08 00"))
    assert_equal(o.m.a, 0)
    assert_equal(o.m.b, 7)


@fieldwise_init
struct Mid(Defaultable, Movable):
    var n: Inner
    var x: Int64
    var tags: List[Int64]

    def __init__(out self):
        self.n = Inner(0, 0)
        self.x = 0
        self.tags = []


@fieldwise_init
struct Top(Defaultable, Movable):
    var m: Mid

    def __init__(out self):
        self.m = Mid()


def test_merge_recurses_and_concatenates_lists() raises:
    # m{n{a:1} tags:[1]} m{x:3} m{n{b:2} tags:[2]}
    var t = from_proto[Top](
        wire("0a 06 0a 02 08 01 18 01  0a 02 10 03  0a 06 0a 02 10 02 18 02")
    )
    assert_equal(t.m.n.a, 1)
    assert_equal(t.m.n.b, 2)
    assert_equal(t.m.x, 3)
    assert_equal(t.m.tags, [1, 2])


@fieldwise_init
struct Lists(Defaultable, Movable):
    var xs: List[Int32]

    @__annotation(ZigZag())
    var zs: List[Int32]
    var fs: List[Float32]
    var bs: List[Bool]
    var names: List[String]

    def __init__(out self):
        self.xs = []
        self.zs = []
        self.fs = []
        self.bs = []
        self.names = []


def test_packed_and_unpacked() raises:
    var l = from_proto[Lists](
        wire(
            # xs: packed [1, 2], unpacked 3, packed [4]
            "0a 02 01 02  08 03  0a 01 04"
            # zs: packed zigzag [-1, 1]
            "  12 02 01 02"
            # fs: packed [1.5, -0.5]
            "  1a 08 00 00 c0 3f 00 00 00 bf"
            # bs: packed [true, false]
            "  22 02 01 00"
            # names: "a", "", "b" -- an empty string is still an element
            "  2a 01 61  2a 00  2a 01 62"
        )
    )
    assert_equal(l.xs, [1, 2, 3, 4])
    assert_equal(l.zs, [-1, 1])
    assert_equal(l.fs, [1.5, -0.5])
    assert_equal(l.bs, [True, False])
    assert_equal(l.names, ["a", "", "b"])


# The encoding guide's packed example: field 4 = [3, 270, 86942].
@fieldwise_init
struct Test5(Defaultable, Movable):
    @__annotation(ProtoTag(4))
    var d: List[Int32]

    def __init__(out self):
        self.d = []


def test_encoding_guide_packed_example() raises:
    var t = from_proto[Test5](wire("22 06 03 8e 02 9e a7 05"))
    assert_equal(t.d, [3, 270, 86942])


def test_empty_packed_run_between_scalars() raises:
    assert_equal(from_proto[Lists](wire("08 01  0a 00  08 02")).xs, [1, 2])


@fieldwise_init
struct Repeated(Defaultable, Movable):
    var items: List[Inner]
    var name: String

    def __init__(out self):
        self.items = []
        self.name = String()


def test_repeated_messages_stay_separate_and_may_interleave() raises:
    # items{a:1} name:"x" items{b:2}
    var r = from_proto[Repeated](wire("0a 02 08 01  12 01 78  0a 02 10 02"))
    assert_equal(len(r.items), 2)
    assert_equal(r.items[0].a, 1)
    assert_equal(r.items[0].b, 0)
    assert_equal(r.items[1].b, 2)
    assert_equal(r.name, "x")


@fieldwise_init
struct Maps(Defaultable, Movable):
    var counts: Dict[String, Int64]
    var byid: Dict[Int32, Inner]

    def __init__(out self):
        self.counts = {}
        self.byid = {}


def test_maps() raises:
    var m = from_proto[Maps](
        wire(
            # counts{"a": 1} counts{"b": 2} counts{"a": 3}: last wins per key
            "0a 05 0a 01 61 10 01  0a 05 0a 01 62 10 02  0a 05 0a 01 61 10 03"
            # counts{"c"} with no value: the value's zero
            "  0a 03 0a 01 63"
            # byid{7: {a: 9}}
            "  12 06 08 07 12 02 08 09"
        )
    )
    assert_equal(len(m.counts), 3)
    assert_equal(m.counts["a"], 3)
    assert_equal(m.counts["b"], 2)
    assert_equal(m.counts["c"], 0)
    assert_equal(m.byid[7].a, 9)


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
struct Drawing(Defaultable, Movable):
    var id: Int32

    @__annotation(ProtoOneof[4, 9]())
    var shape: Optional[Variant[Circle, Square]]

    def __init__(out self):
        self.id = 0
        self.shape = None


def test_oneof_member_and_merge() raises:
    # id:1 circle{r:2} circle{label:"c"}: one member, merged
    var d = from_proto[Drawing](wire("08 01  22 02 08 02  22 03 12 01 63"))
    assert_equal(d.id, 1)
    ref c = d.shape.value()[Circle]
    assert_equal(c.r, 2)
    assert_equal(c.label, "c")


def test_oneof_last_member_wins_and_clears() raises:
    # circle{r:2} square{side:3} circle{label:"c"}: the square cleared the
    # first circle, so r is 0
    var d = from_proto[Drawing](
        wire("22 02 08 02  4a 02 08 03  22 03 12 01 63")
    )
    ref c = d.shape.value()[Circle]
    assert_equal(c.r, 0)
    assert_equal(c.label, "c")
    d = from_proto[Drawing](wire("22 02 08 02  4a 02 08 03"))
    assert_equal(d.shape.value()[Square].side, 3)


def test_oneof_absent_is_none() raises:
    assert_false(Bool(from_proto[Drawing](wire("08 01")).shape))


@fieldwise_init
struct Boxed(Defaultable, Movable):
    var v: Variant[Int64, String]

    def __init__(out self):
        self.v = Int64(0)


def test_variant_without_oneof_is_boxed() raises:
    # v{2: "hi"}: arm 1 (String) is field 2 of the box
    assert_equal(from_proto[Boxed](wire("0a 04 12 02 68 69")).v[String], "hi")
    assert_equal(fail_of[Boxed]("").kind, DerErrorKind.MissingField)


@fieldwise_init
struct Presence(Defaultable, Movable):
    var x: Optional[Int32]
    var m: Optional[Inner]

    def __init__(out self):
        self.x = None
        self.m = None


def test_explicit_presence() raises:
    var p = from_proto[Presence](wire("08 00  12 00"))
    assert_equal(p.x.value(), 0)
    assert_equal(p.m.value().a, 0)
    p = from_proto[Presence](wire(""))
    assert_false(Bool(p.x))
    assert_false(Bool(p.m))


@fieldwise_init
struct Nested(Defaultable, Movable):
    var grid: List[List[Int32]]
    var maybes: List[Optional[Int32]]

    def __init__(out self):
        self.grid = []
        self.maybes = []


def test_nested_containers_are_boxed() raises:
    var n = from_proto[Nested](
        wire(
            # grid: box{1: packed [1, 2]} box{1: packed [3]} box{}
            "0a 04 0a 02 01 02  0a 03 0a 01 03  0a 00"
            # maybes: box{1: 0} box{}
            "  12 02 08 00  12 00"
        )
    )
    assert_equal(len(n.grid), 3)
    assert_equal(n.grid[0], [1, 2])
    assert_equal(n.grid[1], [3])
    assert_equal(len(n.grid[2]), 0)
    assert_equal(n.maybes[0].value(), 0)
    assert_false(Bool(n.maybes[1]))


@fieldwise_init
struct Tuples(Defaultable, Movable):
    var pair: Tuple[Int32, String]
    var arr: Array[Int32, 3]

    def __init__(out self):
        self.pair = (Int32(0), String())
        self.arr = Array[Int32, 3](fill=0)


def test_tuples_are_messages() raises:
    # pair{1: 5, 2: "x"} arr{1: 1, 3: 3}: element 2 absent reads as 0
    var t = from_proto[Tuples](wire("0a 05 08 05 12 01 78  12 04 08 01 18 03"))
    assert_equal(t.pair[0], 5)
    assert_equal(t.pair[1], "x")
    assert_equal(t.arr[0], 1)
    assert_equal(t.arr[1], 0)
    assert_equal(t.arr[2], 3)


def test_root_list_is_boxed() raises:
    assert_equal(from_proto[List[Int32]](wire("0a 03 01 02 03")), [1, 2, 3])


@fieldwise_init
struct Node(Defaultable, Movable):
    var value: Int32
    var children: List[Node]

    def __deinit__(deinit self):
        pass

    def __init__(out self):
        self.value = 0
        self.children = []


def test_recursive_message() raises:
    # value:1 children{value:2 children{value:3}}
    var n = from_proto[Node](wire("08 01  12 06 08 02 12 02 08 03"))
    assert_equal(n.value, 1)
    assert_equal(n.children[0].value, 2)
    assert_equal(n.children[0].children[0].value, 3)


def test_unknown_fields_of_every_wire_type_skipped() raises:
    # 9: varint, 10: fixed64, 11: length-delimited, 12: fixed32, then a: 150
    var t = from_proto[Test1](
        wire(
            "48 96 01  51 01 02 03 04 05 06 07 08  5a 02 aa bb"
            "  65 01 02 03 04  08 96 01"
        )
    )
    assert_equal(t.a, 150)


@__annotation(DenyUnknownFields())
@fieldwise_init
struct Strict(Movable):
    var a: Int32


def test_deny_unknown_fields() raises:
    assert_equal(fail_of[Strict]("10 01").kind, DerErrorKind.UnknownField)


@fieldwise_init
struct _DurationWire(Movable):
    var seconds: Int64
    var nanos: Int32


# google.protobuf.Duration on the wire, one number in Mojo: two `Nanos`
# values can't be merged, but the merged input can be read.
@fieldwise_init
struct Nanos(Deserializable, Movable):
    var total: Int64

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        var w = deserialize[_DurationWire](d)
        return Self(w.seconds * 1_000_000_000 + Int64(w.nanos))


@fieldwise_init
struct Event(Movable):
    var elapsed: Nanos


def test_custom_type_reads_the_merged_message() raises:
    # elapsed{seconds:5} elapsed{nanos:7}
    var e = from_proto[Event](wire("0a 02 08 05  0a 02 10 07"))
    assert_equal(e.elapsed.total, 5_000_000_007)


@__annotation(
    Validate(lambda (b: Bounds) -> Bool: b.lo <= b.hi, "lo must be <= hi")
)
@fieldwise_init
struct Bounds(Movable):
    var lo: Int64
    var hi: Int64


@fieldwise_init
struct Limits(Movable):
    var b: Bounds


def test_validation_runs_once_on_the_merged_message() raises:
    # b{lo:10} b{hi:20}: {lo: 10, hi: 0} on its own would fail
    assert_equal(from_proto[Limits](wire("0a 02 08 0a  0a 02 10 14")).b.hi, 20)
    var f = fail_of[Limits]("0a 02 08 0a  0a 02 10 05")
    assert_equal(f.kind, DerErrorKind.InvalidValue)
    assert_equal(f.path, ".b")


def _double(x: Int64) raises -> Int64:
    return x * 2


@fieldwise_init
struct Annotated(Movable):
    @__annotation(Default(Int32(7)))
    var level: Int32

    @__annotation(Skip())
    var cache: Int32

    @__annotation(Transform(_double))
    var twice: Int64


def test_framework_field_annotations() raises:
    # level absent: its Default; cache is on the wire but skipped; twice 3
    var a = from_proto[Annotated](wire("10 09  18 03"))
    assert_equal(a.level, 7)
    assert_equal(a.cache, 0)
    assert_equal(a.twice, 6)
    # level written explicitly as 0 is 0, not the Default
    assert_equal(from_proto[Annotated](wire("08 00")).level, 0)


def test_transform_reads_the_last_occurrence() raises:
    assert_equal(from_proto[Annotated](wire("18 01  18 05")).twice, 10)


def test_malformed_input() raises:
    # truncated varint
    assert_equal(fail_of[Test1]("08 96").kind, DerErrorKind.InvalidValue)
    # a length past the end of the message
    assert_equal(fail_of[Test1]("12 05 61").kind, DerErrorKind.InvalidValue)
    # field number 0
    assert_equal(fail_of[Test1]("00 01").kind, DerErrorKind.InvalidValue)
    # wire types 6 and 7
    assert_equal(fail_of[Test1]("0e 01").kind, DerErrorKind.InvalidValue)
    # an unterminated group, a mismatched end-group, a stray end-group
    assert_equal(fail_of[Test1]("4b 08 01").kind, DerErrorKind.InvalidValue)
    assert_equal(fail_of[Test1]("4b 54").kind, DerErrorKind.InvalidValue)
    assert_equal(fail_of[Test1]("4c").kind, DerErrorKind.InvalidValue)


def test_tag_limits() raises:
    # A tag is at most 5 bytes, and 2^29 - 1 is the largest field number.
    assert_equal(from_proto[Test1](wire("88 80 80 80 00 05")).a, 5)
    assert_equal(
        fail_of[Test1]("88 80 80 80 80 00 05").kind, DerErrorKind.InvalidValue
    )
    assert_equal(
        fail_of[Test1]("80 80 80 80 10 01").kind, DerErrorKind.InvalidValue
    )
    assert_equal(from_proto[Test1](wire("f8 ff ff ff 0f 01")).a, 0)


@fieldwise_init
struct Kept(Defaultable, Movable):
    var a: Int32
    var b: String
    var rest: UnknownFields

    def __init__(out self):
        self.a = 0
        self.b = String()
        self.rest = UnknownFields()


# What upb does with every input here: a field of the wrong wire type is an
# unknown field, kept in wire order, and written back after the known ones.
def test_wrong_wire_type_is_an_unknown_field() raises:
    # a as length-delimited, a as fixed32, b as a varint, then a: 5
    var k = from_proto[Kept](wire("0a 01 61  0d 01 00 00 00  10 07  08 05"))
    assert_equal(k.a, 5)
    assert_equal(k.b, "")
    assert_equal(k.rest.bytes, wire("0a 01 61  0d 01 00 00 00  10 07"))
    assert_equal(to_proto(k), wire("08 05  0a 01 61  0d 01 00 00 00  10 07"))
    # A message field sent as a varint is unknown too, so m is absent.
    assert_equal(from_proto[Outer](wire("08 01")).m.a, 0)


def test_unknown_groups_are_skipped_and_kept() raises:
    # 9: a group holding a varint and a nested group, then a: 7
    var k = from_proto[Kept](wire("4b 08 01 53 08 02 54 4c  08 07"))
    assert_equal(k.a, 7)
    assert_equal(to_proto(k), wire("08 07  4b 08 01 53 08 02 54 4c"))


@fieldwise_init
struct Holder(Defaultable, Movable):
    var m: Kept
    var x: Int32

    def __init__(out self):
        self.m = Kept()
        self.x = 0


def test_unknown_fields_of_a_split_message_merge() raises:
    # m{9: 1} x:1 m{10: 2}
    var h = from_proto[Holder](wire("0a 02 48 01  10 01  0a 02 50 02"))
    assert_equal(h.m.rest.bytes, wire("48 01  50 02"))
    assert_equal(to_proto(h), wire("0a 04 48 01 50 02  10 01"))


@fieldwise_init
struct KeptMaps(Defaultable, Movable):
    var counts: Dict[String, Int32]
    var rest: UnknownFields

    def __init__(out self):
        self.counts = {}
        self.rest = UnknownFields()


def test_malformed_map_entries_become_unknown_fields() raises:
    # {"a": 1, 3: 9} has an unknown field and {"b": "x"} a mistyped value:
    # upb keeps both entries as unknown fields; {"c": 2} is a map entry.
    var m = from_proto[KeptMaps](
        wire(
            "0a 07 0a 01 61 10 01 18 09  0a 06 0a 01 62 12 01 78  0a 05 0a 01"
            " 63 10 02"
        )
    )
    assert_equal(len(m.counts), 1)
    assert_equal(m.counts["c"], 2)
    assert_equal(
        m.rest.bytes,
        wire("0a 07 0a 01 61 10 01 18 09  0a 06 0a 01 62 12 01 78"),
    )


@fieldwise_init
struct Choice(Defaultable, Movable):
    @__annotation(ProtoOneof[4, 9]())
    var pick: Optional[Variant[Inner, Int32]]

    def __init__(out self):
        self.pick = None


def test_oneof_member_of_the_wrong_wire_type_is_unknown() raises:
    # c{a:2}, then the int32 member as length-delimited: c stays set
    var c = from_proto[Choice](wire("22 02 08 02  4a 01 05"))
    assert_equal(c.pick.value()[Inner].a, 2)


@fieldwise_init
struct Fixeds(Defaultable, Movable):
    @__annotation(Fixed())
    var f: List[UInt32]

    def __init__(out self):
        self.f = []


def test_repeated_field_wire_types() raises:
    # a fixed32 list ignores a varint occurrence, and a packed run that ends
    # mid-value is an error
    assert_equal(len(from_proto[Fixeds](wire("08 05")).f), 0)
    assert_equal(
        fail_of[Fixeds]("0a 03 01 02 03").kind, DerErrorKind.InvalidValue
    )
    # a list whose one occurrence is an empty packed run is empty
    assert_equal(len(from_proto[Test5](wire("22 00")).d), 0)


@fieldwise_init
struct Chain(Defaultable, Movable):
    var child: List[Chain]
    var v: Int32

    def __deinit__(deinit self):
        pass

    def __init__(out self):
        self.child = []
        self.v = 0


def _nested_hex(levels: Int) -> String:
    var inner = List[UInt8]()
    for _ in range(levels):
        var outer: List[UInt8] = [0x0A]
        var n = len(inner)
        while n >= 0x80:
            outer.append(UInt8(n & 0x7F | 0x80))
            n >>= 7
        outer.append(UInt8(n))
        outer.extend(Span(inner))
        inner = outer^
    var text = String()
    for b in inner:
        text += hex(Int(b), prefix="") + " "
    return text^


def test_depth_limit() raises:
    # upb accepts 100 nested messages below the root and rejects 101.
    _ = from_proto[Chain](wire(_nested_hex(100)))
    assert_equal(
        fail_of[Chain](_nested_hex(101)).kind, DerErrorKind.InvalidValue
    )


@fieldwise_init
struct Split(Movable):
    var m: Inner
    var x: Int32


def test_message_split_by_other_fields_merges() raises:
    # m{a:5} x:1 m{b:7} x:2 m{a:0}: each later m run is a repeat, and its
    # replacement re-reads every m occurrence so far
    var s = from_proto[Split](
        wire("0a 02 08 05  10 01  0a 02 10 07  10 02  0a 02 08 00")
    )
    assert_equal(s.m.a, 0)
    assert_equal(s.m.b, 7)
    assert_equal(s.x, 2)


def test_interleaved_map_entries_append() raises:
    # counts{"a": 1} byid{7: {a: 9}} counts{"a": 3} counts{"b": 2}
    var m = from_proto[Maps](
        wire(
            "0a 05 0a 01 61 10 01  12 06 08 07 12 02 08 09"
            "  0a 05 0a 01 61 10 03  0a 05 0a 01 62 10 02"
        )
    )
    assert_equal(m.counts["a"], 3)
    assert_equal(m.counts["b"], 2)
    assert_equal(m.byid[7].a, 9)


@fieldwise_init
struct OptList(Defaultable, Movable):
    var xs: Optional[List[Int32]]
    var n: Int32

    def __init__(out self):
        self.xs = None
        self.n = 0


def test_split_non_appendable_seq_rereads_every_run() raises:
    # xs:1 n:1 xs:2: `Optional[List]` can't be appended to, so its repeat
    # replaces it with every xs occurrence so far
    var o = from_proto[OptList](wire("08 01  10 01  08 02"))
    assert_equal(o.xs.value(), [1, 2])


@fieldwise_init
struct Timed(Movable):
    var elapsed: Nanos
    var n: Int32


def test_split_custom_type_reads_the_merged_message() raises:
    # elapsed{seconds:5} n:1 elapsed{nanos:7}
    var t = from_proto[Timed](wire("0a 02 08 05  10 01  0a 02 10 07"))
    assert_equal(t.elapsed.total, 5_000_000_007)


def test_split_oneof_last_member_wins() raises:
    # circle{r:2} id:1 square{side:3} id:2 circle{label:"c"}
    var d = from_proto[Drawing](
        wire("22 02 08 02  08 01  4a 02 08 03  08 02  22 03 12 01 63")
    )
    ref c = d.shape.value()[Circle]
    assert_equal(c.r, 0)
    assert_equal(c.label, "c")
    assert_equal(d.id, 2)


@fieldwise_init
struct SplitLimits(Movable):
    var b: Bounds
    var x: Int32


# b{lo:10} x:1 b{hi:20}: checked once, on the merged {lo: 10, hi: 20}.
def test_validation_sees_a_message_split_by_other_fields() raises:
    var l = from_proto[SplitLimits](wire("0a 02 08 0a  10 01  0a 02 10 14"))
    assert_equal(l.b.hi, 20)


@fieldwise_init
struct ZigZag32(Movable):
    @__annotation(ZigZag())
    var s: Int32


def test_sint32_truncates_before_decoding() raises:
    # A varint wider than 32 bits: upb keeps the low 32 bits, then decodes.
    assert_equal(from_proto[ZigZag32](wire("08 fe ff ff ff 5e")).s, 2013265919)


@fieldwise_init
struct Pick(Defaultable, Movable):
    @__annotation(ProtoOneof[1, 2]())
    var p: Optional[Variant[String, Int32]]

    def __init__(out self):
        self.p = None


def test_overwritten_occurrences_are_still_validated() raises:
    # b's first occurrence isn't UTF-8; the second would win, but upb has
    # already rejected the first.
    assert_equal(
        fail_of[Test1]("12 01 ff  12 01 61").kind, DerErrorKind.InvalidValue
    )
    # A oneof member cleared by a later one is still parsed first.
    assert_equal(
        fail_of[Pick]("0a 01 ff  10 05").kind, DerErrorKind.InvalidValue
    )


@fieldwise_init
struct MsgMap(Defaultable, Movable):
    var m: Dict[Int32, Inner]
    var rest: UnknownFields

    def __init__(out self):
        self.m = {}
        self.rest = UnknownFields()


# Each input has an unknown field 3 in its entry; the expected bytes are
# what upb writes back for it.
def test_malformed_entries_are_rewritten_canonically() raises:
    # zero key and value drop out
    assert_equal(
        from_proto[KeptMaps](wire("0a 06 0a 00 10 00 18 09")).rest.bytes,
        wire("0a 02 18 09"),
    )
    # the last key wins, varints come out minimal, known fields go first
    assert_equal(
        from_proto[KeptMaps](
            wire("0a 0b 18 09 0a 01 61 0a 01 62 10 81 00")
        ).rest.bytes,
        wire("0a 07 0a 01 62 10 01 18 09"),
    )
    # a split value merges
    assert_equal(
        from_proto[MsgMap](
            wire("0a 0c 08 01 12 02 08 05 12 02 10 06 18 09")
        ).rest.bytes,
        wire("0a 0a 08 01 12 04 08 05 10 06 18 09"),
    )


@fieldwise_init
struct Leaf(Copyable, Movable):
    var x: Int32


@fieldwise_init
struct Deep(Defaultable, Movable):
    var child: List[Deep]
    var m: Dict[Int32, Leaf]

    def __deinit__(deinit self):
        pass

    def __init__(out self):
        self.child = []
        self.m = {}


def _deep_hex(levels: Int) -> String:
    # m {1: {x: 5}} at the bottom of `levels` nested children
    var chain: List[UInt8] = [0x12, 0x06, 0x08, 0x01, 0x12, 0x02, 0x08, 0x05]
    for _ in range(levels):
        var outer: List[UInt8] = [0x0A]
        var n = len(chain)
        while n >= 0x80:
            outer.append(UInt8(n & 0x7F | 0x80))
            n >>= 7
        outer.append(UInt8(n))
        outer.extend(Span(chain))
        chain = outer^
    var text = String()
    for b in chain:
        text += hex(Int(b), prefix="") + " "
    return text^


def test_map_entries_count_toward_the_depth_limit() raises:
    # The entry and its value are two levels: upb takes 98 children above
    # the map, not 99.
    var d = from_proto[Deep](wire(_deep_hex(98)))
    assert_equal(len(d.child), 1)
    assert_equal(fail_of[Deep](_deep_hex(99)).kind, DerErrorKind.InvalidValue)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
