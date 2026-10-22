from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    TestSuite,
)
from std.utils import Variant
from _xml_format import (
    from_xml,
    from_xml_bytes,
    to_xml,
    xml_canonical,
    XmlAttr,
    XmlMixed,
    XmlNs,
    XmlText,
    XmlTextRun,
)
from emberserde.deserialize import Deserializable, Deserializer
from emberserde.serialize import Serializable, Serializer
from emberserde.error import SerializationError
from emberserde.error import DerErrorKind, DeserializationError
from emberserde.field import Alias, Default, Rename, Skip, Transform
from emberserde.struct_modifiers import (
    DenyUnknownFields,
    RenameAll,
    arm_tag,
)
from emberserde.validate import Range, Size, Validate


# What a failing read raised; an empty message means it did not raise.
@fieldwise_init
struct Failure(Copyable, Movable):
    var kind: DerErrorKind
    var message: String
    var path: String


# What the parser alone raises for a document, whatever it maps to.
def parse_error(doc: StringSlice) raises -> Failure:
    var f = Failure(DerErrorKind.Custom, String(), String())
    try:
        _ = xml_canonical(List[UInt8](doc.as_bytes()))
    except e:
        f = Failure(e.kind, e.message, e.path)
    return f^


def fail_of[T: Deinitable](var s: String) raises -> Failure:
    var f = Failure(DerErrorKind.Custom, String(), String())
    try:
        _ = from_xml[T](s^)
    except e:
        f = Failure(e.kind, e.message, e.path)
    return f^


def assert_fails[
    T: Deinitable
](var s: String, kind: DerErrorKind, path: String = "") raises:
    var f = fail_of[T](s^)
    assert_true(f.message.byte_length() > 0, "expected the read to fail")
    assert_equal(f.kind, kind)
    assert_equal(f.path, path)


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct Line(Copyable, Movable):
    var a: Point
    var b: Point


def test_primitives() raises:
    assert_equal(from_xml[Int]("<value>5</value>"), 5)
    assert_equal(from_xml[Int64]("<n>-3</n>"), -3)
    assert_equal(from_xml[Float64]("<value>1.5</value>"), 1.5)
    assert_equal(from_xml[Bool]("<value>true</value>"), True)
    assert_equal(from_xml[Bool]("<value>0</value>"), False)
    assert_equal(from_xml[String]("<value>hello</value>"), "hello")
    assert_equal(from_xml[String]("<value/>"), "")
    assert_equal(from_xml[String]("<value></value>"), "")


def test_numbers_trimmed_strings_verbatim() raises:
    assert_equal(from_xml[Int]("<value>  7\n</value>"), 7)
    assert_equal(from_xml[String]("<value> a </value>"), " a ")


def test_escapes() raises:
    assert_equal(
        from_xml[String](
            "<value>a &lt;b&gt; &amp; &quot;c&quot; &apos;d&apos;</value>"
        ),
        "a <b> & \"c\" 'd'",
    )
    assert_equal(from_xml[String]("<value>&#65;&#x42;&#x263A;</value>"), "AB☺")


def test_cdata() raises:
    assert_equal(
        from_xml[String]("<value>x<![CDATA[<raw> & ]]>y</value>"), "x<raw> & y"
    )


def test_prolog_comments_and_pis() raises:
    assert_equal(
        from_xml[Int](
            '<?xml version="1.0"?><!-- c --><!DOCTYPE value>\n'
            "<value><!-- inside -->5<?pi x?></value><!-- after -->\n"
        ),
        5,
    )


def test_struct_any_order_any_root_name() raises:
    var p = from_xml[Point]("<Point><x>1</x><y>2</y></Point>")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)
    p = from_xml[Point]("<Anything>\n  <y>4</y>\n  <x>3</x>\n</Anything>")
    assert_equal(p.x, 3)
    assert_equal(p.y, 4)


def test_duplicate_singular_struct_field() raises:
    assert_fails[Line](
        (
            "<Line><a><x>1</x><y>2</y></a><b><x>3</x><y>4</y></b>"
            "<a><x>5</x><y>6</y></a></Line>"
        ),
        DerErrorKind.DuplicateField,
        ".a",
    )


def test_nested_struct() raises:
    var l = from_xml[Line](
        "<Line><b><x>3</x><y>4</y></b><a><x>1</x><y>2</y></a></Line>"
    )
    assert_equal(l.a.x, 1)
    assert_equal(l.b.y, 4)


@__annotation(XmlNs("urn:p"))
@fieldwise_init
struct NsPoint(Copyable, Movable):
    var x: Int

    @__annotation(XmlNs("urn:other"))
    var y: Int

    @__annotation(XmlAttr(), XmlNs("urn:a"))
    var tag: Int

    @__annotation(XmlAttr())
    var plain: Int


def test_names_match_by_expanded_name() raises:
    # Any prefix (or the default namespace) works; the namespace must match.
    var p = from_xml[NsPoint](
        '<p:P xmlns:p="urn:p" xmlns:o="urn:other" xmlns:a="urn:a"'
        ' a:tag="3" plain="4"><p:x>1</p:x><o:y>2</o:y></p:P>'
    )
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)
    assert_equal(p.tag, 3)
    assert_equal(p.plain, 4)
    p = from_xml[NsPoint](
        '<P xmlns="urn:p" xmlns:a="urn:a" a:tag="3" plain="4"><x>1</x>'
        '<y xmlns="urn:other">2</y></P>'
    )
    assert_equal(p.y, 2)
    # The same local names in other namespaces are other fields.
    assert_fails[NsPoint](
        '<P xmlns="urn:p" tag="3" plain="4"><x>1</x><y>2</y></P>',
        DerErrorKind.MissingField,
        ".y",
    )
    assert_fails[Point](
        '<P xmlns="urn:y"><x>1</x><y>2</y></P>', DerErrorKind.MissingField, ".x"
    )


@fieldwise_init
struct Link(Defaultable, Movable):
    @__annotation(XmlAttr())
    var href: String

    @__annotation(XmlText())
    var label: String

    @__annotation(XmlAttr())
    var rel: Optional[String]

    def __init__(out self):
        self.href = ""
        self.label = ""
        self.rel = None


def test_attributes_and_text() raises:
    var l = from_xml[Link]('<Link href="/a?x=1&amp;y=2">Home</Link>')
    assert_equal(l.href, "/a?x=1&y=2")
    assert_equal(l.label, "Home")
    assert_false(Bool(l.rel))
    l = from_xml[Link](
        "<a:Link xmlns:a='urn:a' rel='nofollow' href='/b'>&lt;b&gt;</a:Link>"
    )
    assert_equal(l.rel.value(), "nofollow")
    assert_equal(l.label, "<b>")


def test_absent_text_is_empty() raises:
    assert_equal(from_xml[Link]('<Link href="/"/>').label, "")


@fieldwise_init
struct Para(Defaultable, Movable):
    @__annotation(XmlText())
    var body: String
    var b: List[String]

    def __init__(out self):
        self.body = ""
        self.b = []


# An `XmlText` field collects the text apart from the children, so mixed
# content keeps its pieces but loses their interleaving; `XmlMixed` keeps it.
def test_mixed_content() raises:
    var p = from_xml[Para]("<p>Hello <b>big</b> world<b>!</b></p>")
    assert_equal(p.body, "Hello  world")
    assert_equal(p.b, ["big", "!"])


@fieldwise_init
struct Feed(Defaultable, Movable):
    var title: String
    var item: List[String]

    def __init__(out self):
        self.title = ""
        self.item = []


def test_unwrapped_list() raises:
    var f = from_xml[Feed](
        "<Feed><title>t</title><item>a</item><item>b</item></Feed>"
    )
    assert_equal(f.title, "t")
    assert_equal(f.item, ["a", "b"])


def test_interleaved_list() raises:
    var f = from_xml[Feed](
        "<Feed><item>a</item><title>t</title><item>b</item></Feed>"
    )
    assert_equal(f.title, "t")
    assert_equal(f.item, ["a", "b"])


@fieldwise_init
struct Mix(Defaultable, Movable):
    var a: List[Int]
    var b: List[Int]

    def __init__(out self):
        self.a = []
        self.b = []


def test_two_interleaved_lists() raises:
    var m = from_xml[Mix]("<Mix><a>1</a><b>2</b><a>3</a><b>4</b></Mix>")
    assert_equal(m.a, [1, 3])
    assert_equal(m.b, [2, 4])


def test_absent_list_is_empty() raises:
    assert_equal(len(from_xml[Feed]("<Feed><title>t</title></Feed>").item), 0)


def test_missing_required_field() raises:
    assert_fails[Feed](
        "<Feed><item>a</item></Feed>", DerErrorKind.MissingField, ".title"
    )


def test_duplicate_singular_field() raises:
    assert_fails[Feed](
        "<Feed><title>a</title><title>b</title></Feed>",
        DerErrorKind.DuplicateField,
        ".title",
    )


@fieldwise_init
struct Grid(Defaultable, Movable):
    var row: List[List[Int]]

    def __init__(out self):
        self.row = []


def test_nested_list_is_boxed() raises:
    var g = from_xml[Grid](
        "<Grid><row><item>1</item><item>2</item></row><row><v>3</v></row>"
        "<row/></Grid>"
    )
    assert_equal(len(g.row), 3)
    assert_equal(g.row[0], [1, 2])
    assert_equal(g.row[1], [3])
    assert_equal(len(g.row[2]), 0)


@fieldwise_init
struct Poly(Defaultable, Movable):
    var pt: List[Point]

    def __init__(out self):
        self.pt = []


def test_list_of_structs() raises:
    var p = from_xml[Poly](
        "<Poly><pt><x>1</x><y>2</y></pt><pt><x>3</x><y>4</y></pt></Poly>"
    )
    assert_equal(len(p.pt), 2)
    assert_equal(p.pt[1].x, 3)


def test_root_list_is_boxed() raises:
    assert_equal(
        from_xml[List[Int]]("<value><item>1</item><item>2</item></value>"),
        [1, 2],
    )


@fieldwise_init
struct Env(Defaultable, Movable):
    var vars: Dict[String, Int]
    var lists: Dict[String, List[Int]]

    def __init__(out self):
        self.vars = {}
        self.lists = {}


def test_map_field_one_element_per_entry() raises:
    var e = from_xml[Env](
        "<Env><vars><key>a</key><value>1</value></vars>"
        "<lists><key>x</key><value>1</value><value>2</value></lists>"
        "<vars><key>b</key><value>2</value></vars></Env>"
    )
    assert_equal(len(e.vars), 2)
    assert_equal(e.vars["a"], 1)
    assert_equal(e.vars["b"], 2)
    assert_equal(e.lists["x"], [1, 2])


def test_interleaved_map_later_entry_wins() raises:
    var e = from_xml[Env](
        "<Env><vars><key>a</key><value>1</value></vars><x/>"
        "<vars><key>a</key><value>2</value></vars></Env>"
    )
    assert_equal(len(e.vars), 1)
    assert_equal(e.vars["a"], 2)


def test_map_entry_shape() raises:
    var e = from_xml[Env](
        "<Env><vars><value>2</value><x/><key>b</key></vars></Env>"
    )
    assert_equal(e.vars["b"], 2)
    assert_fails[Env](
        "<Env><vars><value>2</value></vars></Env>",
        DerErrorKind.MissingField,
        ".vars[0]",
    )
    assert_fails[Env](
        "<Env><vars><key>a</key><value>1</value><value>2</value></vars></Env>",
        DerErrorKind.DuplicateField,
        ".vars",
    )


def test_root_map() raises:
    var m = from_xml[Dict[String, Int]](
        "<value><entry><key>a</key><value>1</value></entry></value>"
    )
    assert_equal(m["a"], 1)


def test_map_entry_missing_value() raises:
    assert_fails[Dict[String, Int]](
        "<value><entry><key>a</key></entry></value>",
        DerErrorKind.MissingField,
        "[0]",
    )


@fieldwise_init
struct Seg(Defaultable, Movable):
    var ends: Tuple[Int, Int]

    def __init__(out self):
        self.ends = (0, 0)


def test_tuples_and_arrays() raises:
    var t = from_xml[Tuple[Int, String]](
        "<value><item>1</item><item>x</item></value>"
    )
    assert_equal(t[0], 1)
    assert_equal(t[1], "x")
    var a = from_xml[Array[Int, 3]](
        "<value><item>1</item><item>2</item><item>3</item></value>"
    )
    assert_equal(a[2], 3)
    var s = from_xml[Seg](
        "<Seg><ends><item>4</item><item>5</item></ends></Seg>"
    )
    assert_equal(s.ends[1], 5)
    var v = from_xml[SIMD[DType.int32, 2]](
        "<value><item>6</item><item>7</item></value>"
    )
    assert_equal(v[1], 7)


def test_tuple_arity_checked() raises:
    assert_fails[Tuple[Int, Int]](
        "<value><item>1</item></value>", DerErrorKind.InvalidValue, "[1]"
    )
    assert_fails[Tuple[Int, Int]](
        "<value><item>1</item><item>2</item><item>3</item></value>",
        DerErrorKind.InvalidValue,
        "[2]",
    )


@fieldwise_init
struct Opt(Defaultable, Movable):
    var a: Optional[Int]
    var s: Optional[String]
    var xs: List[Optional[Int]]

    def __init__(out self):
        self.a = None
        self.s = None
        self.xs = []


def test_optional() raises:
    var o = from_xml[Opt]("<Opt/>")
    assert_false(Bool(o.a))
    assert_false(Bool(o.s))
    o = from_xml[Opt]('<Opt><a>5</a><s/><xs>1</xs><xs nil="true"/></Opt>')
    assert_equal(o.a.value(), 5)
    assert_equal(o.s.value(), "")
    assert_equal(len(o.xs), 2)
    assert_equal(o.xs[0].value(), 1)
    assert_false(Bool(o.xs[1]))
    o = from_xml[Opt]('<Opt><a nil="true"/><s nil="true"/></Opt>')
    assert_false(Bool(o.a))
    assert_false(Bool(o.s))


def test_root_optional() raises:
    assert_false(Bool(from_xml[Optional[Int]]('<value nil="true"/>')))
    assert_equal(from_xml[Optional[Int]]("<value>3</value>").value(), 3)


@__annotation(Rename("circle"))
@fieldwise_init
struct Circle(Copyable, Movable):
    var r: Int


@__annotation(Rename("square"))
@fieldwise_init
struct Square(Copyable, Movable):
    var side: Int


comptime Shape = Variant[Circle, Square]


@fieldwise_init
struct Scene(Defaultable, Movable):
    var shape: Shape
    var shapes: List[Shape]

    def __init__(out self):
        self.shape = Shape(Circle(0))
        self.shapes = []


def test_variant_struct_arms() raises:
    var s = from_xml[Scene](
        '<Scene><shapes variant="circle"><r>1</r></shapes>'
        '<shape variant="square"><side>2</side></shape>'
        '<shapes variant="square"><side>3</side></shapes></Scene>'
    )
    assert_true(s.shape.isa[Square]())
    assert_equal(s.shape[Square].side, 2)
    assert_equal(len(s.shapes), 2)
    assert_equal(s.shapes[0][Circle].r, 1)
    assert_equal(s.shapes[1][Square].side, 3)


@__annotation(DenyUnknownFields())
@fieldwise_init
struct Strict(Copyable, Movable):
    var a: Int


def test_variant_payload_ignores_its_tag() raises:
    var v = from_xml[Variant[Strict, Int]](
        String(t'<value variant="{arm_tag[Strict]()}"><a>1</a></value>')
    )
    assert_equal(v[Strict].a, 1)


def test_variant_scalar_and_list_arms() raises:
    var v = from_xml[Variant[Int64, String]](
        '<value variant="String">hi</value>'
    )
    assert_equal(v[String], "hi")
    v = from_xml[Variant[Int64, String]](
        String(t'<value variant="{arm_tag[Int64]()}">5</value>')
    )
    assert_equal(v[Int64], 5)
    var l = from_xml[Variant[List[Int], String]](
        String(t'<value variant="{arm_tag[List[Int]]()}">')
        + "<item>1</item><item>2</item></value>"
    )
    assert_equal(l[List[Int]], [1, 2])


def test_variant_errors() raises:
    assert_fails[Shape](
        '<value variant="triangle"/>', DerErrorKind.UnknownVariant
    )
    assert_fails[Shape]("<value><r>1</r></value>", DerErrorKind.TypeMismatch)


@fieldwise_init
struct ByteBuf(Copyable, Deserializable, Movable, Serializable):
    var data: List[Byte]

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bytes(Span(self.data))

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_bytes())


def test_bytes() raises:
    assert_equal(from_xml[ByteBuf]("<value>01ff0A</value>").data, [1, 255, 10])
    assert_equal(len(from_xml[ByteBuf]("<value/>").data), 0)
    assert_fails[ByteBuf]("<value>abc</value>", DerErrorKind.InvalidValue)


def _parse_level(s: String) raises -> Int:
    if s == "low":
        return 1
    if s == "high":
        return 2
    raise Error("bad level")


@__annotation(RenameAll(.CamelCase))
@fieldwise_init
struct Annotated(Defaultable, Movable):
    @__annotation(Rename("full-name"))
    var name: String

    @__annotation(Alias("years"))
    var age_years: Int

    @__annotation(Skip())
    var cache: Int

    @__annotation(Default(8080))
    var port: Int

    @__annotation(Range(0, 10))
    var score: Int

    @__annotation(Transform(_parse_level))
    var level: Int

    @__annotation(Size(1, 2))
    var tag: List[String]

    def __init__(out self):
        self.name = ""
        self.age_years = 0
        self.cache = 0
        self.port = 0
        self.score = 0
        self.level = 0
        self.tag = []


def test_framework_annotations() raises:
    var a = from_xml[Annotated](
        "<A><full-name>Ann</full-name><years>3</years><cache>9</cache>"
        "<score>4</score><level>high</level><tag>x</tag></A>"
    )
    assert_equal(a.name, "Ann")
    assert_equal(a.age_years, 3)
    assert_equal(a.cache, 0)
    assert_equal(a.port, 8080)
    assert_equal(a.score, 4)
    assert_equal(a.level, 2)
    assert_equal(a.tag, ["x"])
    a = from_xml[Annotated](
        "<A><fullName>no</fullName><full-name>B</full-name><ageYears>1</ageYears>"
        "<port>1</port><score>0</score><level>low</level><tag>p</tag></A>"
    )
    assert_equal(a.age_years, 1)
    assert_equal(a.port, 1)
    assert_fails[Annotated](
        (
            "<A><full-name>B</full-name><ageYears>1</ageYears><score>11</score>"
            "<level>low</level><tag>p</tag></A>"
        ),
        DerErrorKind.InvalidValue,
        ".score",
    )
    assert_fails[Annotated](
        (
            "<A><full-name>B</full-name><ageYears>1</ageYears><score>1</score>"
            "<level>mid</level><tag>p</tag></A>"
        ),
        DerErrorKind.InvalidValue,
        ".level",
    )


# The list check runs once, after every occurrence has been appended.
def test_checks_see_the_appended_list() raises:
    var base = String(
        "<A><full-name>B</full-name><ageYears>1</ageYears><score>1</score>"
    )
    assert_equal(
        len(
            from_xml[Annotated](
                base + "<tag>p</tag><level>low</level><tag>q</tag></A>"
            ).tag
        ),
        2,
    )
    assert_fails[Annotated](
        base + "<tag>p</tag><level>low</level><tag>q</tag><tag>r</tag></A>",
        DerErrorKind.InvalidValue,
        ".tag",
    )


@__annotation(
    Validate(lambda (r: Bounds) -> Bool: r.lo <= r.hi, "lo must be <= hi")
)
@fieldwise_init
struct Bounds(Movable):
    @__annotation(XmlAttr())
    var lo: Int

    @__annotation(XmlAttr())
    var hi: Int


def test_struct_validation() raises:
    assert_equal(from_xml[Bounds]('<B lo="1" hi="2"/>').hi, 2)
    assert_fails[Bounds]('<B lo="3" hi="2"/>', DerErrorKind.InvalidValue)


def test_deny_unknown_fields() raises:
    # A namespace declaration is not an attribute field.
    assert_equal(from_xml[Strict]('<S xmlns:p="urn:p"><a>1</a></S>').a, 1)
    assert_fails[Strict](
        '<S xmlns="urn:s"><a>1</a></S>', DerErrorKind.UnknownField
    )
    assert_fails[Strict]("<S><a>1</a><b>2</b></S>", DerErrorKind.UnknownField)
    assert_fails[Strict]('<S z="1"><a>1</a></S>', DerErrorKind.UnknownField)


def test_unknown_fields_skipped() raises:
    var p = from_xml[Point](
        '<Point extra="1"><z><deep>1</deep></z><x>1</x><y>2</y></Point>'
    )
    assert_equal(p.x, 1)


def test_shape_mismatches() raises:
    assert_fails[Int]("<value><b>1</b></value>", DerErrorKind.TypeMismatch)
    assert_fails[Line](
        '<Line a="1"><b><x>1</x><y>2</y></b></Line>',
        DerErrorKind.TypeMismatch,
        ".a",
    )


def test_malformed() raises:
    assert_fails[Int]("", DerErrorKind.InvalidValue)
    assert_fails[Int]("<value>1", DerErrorKind.InvalidValue)
    assert_fails[Int]("<value>1</other>", DerErrorKind.InvalidValue)
    assert_fails[Int]("<value>1</value>x", DerErrorKind.InvalidValue)
    assert_fails[Int](
        "<value>1</value><value>2</value>", DerErrorKind.InvalidValue
    )
    assert_fails[String]("<value>&nope;</value>", DerErrorKind.InvalidValue)
    assert_fails[Point]("<Point x=1/>", DerErrorKind.InvalidValue)
    assert_fails[Int]("<value>abc</value>", DerErrorKind.InvalidValue)
    assert_fails[Bool]("<value>yes</value>", DerErrorKind.InvalidValue)


@fieldwise_init
struct Rich(Defaultable, Movable):
    @__annotation(XmlAttr())
    var id: Int

    @__annotation(XmlText())
    var note: String
    var line: Line
    var tags: List[String]
    var grid: List[List[Int]]
    var env: Dict[String, Optional[Int]]
    var pair: Tuple[Int, String]
    var shape: Shape
    var maybe: Optional[Point]
    var blob: ByteBuf

    def __init__(out self):
        self.id = 0
        self.note = ""
        self.line = Line(Point(0, 0), Point(0, 0))
        self.tags = []
        self.grid = []
        self.env = {}
        self.pair = Tuple[Int, String](0, "")
        self.shape = Shape(Circle(0))
        self.maybe = None
        self.blob = ByteBuf([])


def test_round_trip() raises:
    var env = Dict[String, Optional[Int]]()
    env["a"] = 1
    env["b"] = None
    var r = Rich()
    r.id = 7
    r.note = 'a < b & "c"'
    r.line = Line(Point(1, 2), Point(3, 4))
    r.tags = ["x", "", "z"]
    r.grid = [[1, 2], [], [3]]
    r.env = env^
    r.pair = Tuple[Int, String](5, "five")
    r.shape = Shape(Circle(9))
    r.maybe = Point(0, 0)
    r.blob = ByteBuf([0, 128, 255])
    var back = from_xml[Rich](to_xml(r))
    assert_equal(back.id, 7)
    assert_equal(back.note, r.note)
    assert_equal(back.line.b.y, 4)
    assert_equal(back.tags, r.tags)
    assert_equal(len(back.grid), 3)
    assert_equal(back.grid[0], [1, 2])
    assert_equal(len(back.grid[1]), 0)
    assert_equal(back.env["a"].value(), 1)
    assert_false(Bool(back.env["b"]))
    assert_equal(back.pair[1], "five")
    assert_equal(back.shape[Circle].r, 9)
    assert_equal(back.maybe.value().x, 0)
    assert_equal(back.blob.data, [0, 128, 255])


def test_line_ends_normalized() raises:
    assert_equal(from_xml[String]("<value>a\r\nb\rc</value>"), "a\nb\nc")
    # A character reference is data, so it is not normalized.
    assert_equal(from_xml[String]("<value>a&#13;b</value>"), "a\rb")


@fieldwise_init
struct Tagged(Defaultable, Movable):
    @__annotation(XmlAttr())
    var a: String

    @__annotation(XmlAttr())
    var kind: Optional[String]

    def __init__(out self):
        self.a = ""
        self.kind = None


def test_attribute_value_normalization() raises:
    # Whitespace characters become spaces; references to them don't.
    assert_equal(from_xml[Tagged]('<T a="x\ny\tz&#10;w&#9;"/>').a, "x y z\nw\t")
    # '<' may arrive by character reference, just not literally.
    assert_equal(
        from_xml[Tagged]('<!DOCTYPE T [<!ENTITY e "x">]><T a="&e;&#60;"/>').a,
        "x<",
    )


def test_internal_subset_entities_and_defaults() raises:
    var t = from_xml[Tagged](
        '<!DOCTYPE T [<!ENTITY who "World"><!ENTITY hi "Hi, &who;!">'
        '<!ATTLIST T a CDATA " sp " kind NMTOKEN "  plain  ">]>'
        '<T a="&hi;"/>'
    )
    assert_equal(t.a, "Hi, World!")
    assert_equal(t.kind.value(), "plain")
    t = from_xml[Tagged](
        "<!DOCTYPE T [<!ATTLIST T kind NMTOKEN #IMPLIED>]>"
        '<T a="" kind="  a   b "/>'
    )
    assert_equal(t.kind.value(), "a b")
    # An entity's replacement text is parsed as content, markup included.
    var p = from_xml[Point](
        '<!DOCTYPE P [<!ENTITY xy "<x>1</x><y>&#50;</y>">]><P>&xy;</P>'
    )
    assert_equal(p.y, 2)


def test_unread_declarations_are_unsupported() raises:
    for doc in [
        '<!DOCTYPE v SYSTEM "v.dtd"><value>&e;</value>',
        '<!DOCTYPE v [<!ENTITY e SYSTEM "e.xml">]><value>&e;</value>',
        # Declarations after an unread parameter entity aren't processed.
        (
            '<!DOCTYPE v [<!ENTITY % x SYSTEM "x.dtd">%x;<!ENTITY e "late">]>'
            "<value>&e;</value>"
        ),
    ]:
        var f = fail_of[String](String(doc))
        assert_equal(f.kind, DerErrorKind.InvalidValue)
        assert_true(f.message.startswith("unsupported:"), f.message)
    assert_equal(
        from_xml[String](
            '<?xml version="1.0" standalone="yes"?><!DOCTYPE v [<!ENTITY %'
            ' x SYSTEM "x.dtd">%x;<!ENTITY e "late">]><value>&e;</value>'
        ),
        "late",
    )
    assert_true(
        fail_of[String]("<value>&e;</value>").message.startswith(
            "not well-formed: undeclared"
        )
    )


def test_not_well_formed() raises:
    for doc in [
        '<value a="<"/>',
        "<value>]]></value>",
        "<value><!-- a -- b --></value>",
        '<value b="1" b="2"/>',
        '<value a="1"b="2"/>',
        "<value>&#0;</value>",
        "<value>\x01</value>",
        "<value>a & b</value>",
        '<?xml version="1.0"?><?xml version="1.0"?><value/>',
        '<?XML version="1.0"?><value/>',
        "<?xml version='2.0'?><value/>",
        "<value/><value/>",
        "<value/>tail",
        "<1value/>",
        "<a:b:c/>",
        "<value><![CDATA[x</value>",
        '<!DOCTYPE v [<!ENTITY e "&e;">]><value>&e;</value>',
        '<!DOCTYPE v [<!ENTITY e "<b>">]><value>&e;</b></value>',
        '<!DOCTYPE v [<!ENTITY e "<">]><value a="&e;"/>',
        '<!DOCTYPE v [<!ENTITY e SYSTEM "e.xml">]><value a="&e;"/>',
        "<!DOCTYPE v [<!ELEMENT v (a|b,c)>]><value/>",
        '<!DOCTYPE v [<!ENTITY e "%p;">]><value/>',
        "<!DOCTYPE v [<![INCLUDE[]]>]><value/>",
    ]:
        var f = parse_error(doc)
        assert_equal(f.kind, DerErrorKind.InvalidValue, String(doc))
        assert_true(f.message.startswith("not well-formed:"), f.message)


def test_namespace_well_formedness() raises:
    for doc in [
        "<p:value/>",
        '<value xmlns:p=""/>',
        '<value xmlns:xml="urn:x"/>',
        '<value xmlns:xmlns="urn:x"/>',
        '<value xmlns:p="http://www.w3.org/2000/xmlns/"/>',
        '<value xmlns="http://www.w3.org/XML/1998/namespace"/>',
        '<value xmlns:a="urn:x" xmlns:b="urn:x" a:c="1" b:c="2"/>',
        "<value p:a='1'/>",
        "<?a:b x?><value/>",
        '<!DOCTYPE v [<!ENTITY a:b "x">]><value/>',
    ]:
        var f = parse_error(doc)
        assert_equal(f.kind, DerErrorKind.InvalidValue, String(doc))
    # A prefix's scope ends with its element, and the default namespace
    # can be undeclared.
    assert_equal(
        from_xml[Point](
            '<P xmlns="urn:q"><x xmlns="">1</x><y xmlns="">2</y></P>'
        ).y,
        2,
    )


def test_entity_expansion_is_capped() raises:
    var doc = String('<!DOCTYPE v [<!ENTITY a0 "lollollollollol">')
    for i in range(1, 10):
        doc += String(t'<!ENTITY a{i} "')
        for _ in range(10):
            doc += String(t"&a{i - 1};")
        doc += '">'
    doc += ']><value a="&a9;"/>'
    var f = parse_error(doc)
    assert_true(f.message.find("amplification") >= 0, f.message)


def _utf16(s: String, le: Bool, bom: Bool) -> List[UInt8]:
    var units = List[Int]()
    if bom:
        units.append(0xFEFF)
    for cp in s.codepoints():
        var c = Int(cp)
        if c >= 0x10000:
            units.append(0xD800 + ((c - 0x10000) >> 10))
            units.append(0xDC00 + ((c - 0x10000) & 0x3FF))
        else:
            units.append(c)
    var out = List[UInt8]()
    for u in units:
        var hi = UInt8(u >> 8)
        var lo = UInt8(u & 0xFF)
        out.append(lo if le else hi)
        out.append(hi if le else lo)
    return out^


def _bytes(s: StringSlice) -> List[UInt8]:
    return List[UInt8](s.as_bytes())


def test_encodings() raises:
    var text = String("<value>hé\U0001F600</value>")
    assert_equal(
        from_xml_bytes[String](_utf16(text, True, True)), "hé\U0001F600"
    )
    assert_equal(
        from_xml_bytes[String](_utf16(text, False, True)), "hé\U0001F600"
    )
    assert_equal(
        from_xml_bytes[String](
            _utf16(
                String(
                    '<?xml version="1.0" encoding="UTF-16LE"?><value>x</value>'
                ),
                True,
                False,
            )
        ),
        "x",
    )
    var latin = _bytes("<?xml version='1.0' encoding='ISO-8859-1'?><value>")
    latin.append(0xE9)
    latin += _bytes("</value>")
    assert_equal(from_xml_bytes[String](latin^), "é")
    var bad = List[List[UInt8]]()
    var invalid_utf8 = _bytes("<v/>")
    invalid_utf8.append(0xFF)
    bad.append(invalid_utf8^)
    var ascii = _bytes("<?xml version='1.0' encoding='US-ASCII'?><v>")
    ascii.append(0xE9)
    ascii += _bytes("</v>")
    bad.append(ascii^)
    var bom_latin = List[UInt8]()
    bom_latin.append(0xEF)
    bom_latin.append(0xBB)
    bom_latin.append(0xBF)
    bom_latin += _bytes("<?xml version='1.0' encoding='ISO-8859-1'?><v/>")
    bad.append(bom_latin^)
    bad.append(_bytes("<?xml version='1.0' encoding='KOI8-R'?><v/>"))
    bad.append(
        _utf16(
            String('<?xml version="1.0" encoding="UTF-16"?><v/>'), True, False
        )
    )
    for b in bad:
        var raised = False
        try:
            _ = from_xml_bytes[String](b.copy())
        except e:
            raised = True
            assert_equal(e.kind, DerErrorKind.InvalidValue)
        assert_true(raised)


# All of an element's direct character data, wherever it falls between the
# children, including between same-named siblings.
def test_text_field_gets_all_direct_text() raises:
    var p = from_xml[Para]("<p>a <b>x</b> <b>y</b>\n c</p>")
    assert_equal(p.body, "a  \n c")
    assert_equal(p.b, ["x", "y"])


@__annotation(Rename("b"))
@fieldwise_init
struct Bold(Copyable, Defaultable, Movable):
    @__annotation(XmlText())
    var text: String

    def __init__(out self):
        self.text = String()


@__annotation(Rename("i"))
@fieldwise_init
struct Italic(Copyable, Defaultable, Movable):
    @__annotation(XmlText())
    var text: String

    def __init__(out self):
        self.text = String()


@__annotation(Rename("a"))
@fieldwise_init
struct MixLink(Copyable, Defaultable, Movable):
    @__annotation(XmlAttr())
    var href: String

    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Bold]]

    def __init__(out self):
        self.href = String()
        self.content = []


@__annotation(Rename("p"))
@fieldwise_init
struct MixPara(Defaultable, Movable):
    @__annotation(XmlAttr())
    var id: Optional[String]

    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Bold, Italic, MixLink]]

    def __init__(out self):
        self.id = None
        self.content = []


def _parts(content: List[Variant[XmlTextRun, Bold, Italic, MixLink]]) -> String:
    var out = String()
    for part in content:
        if part.isa[XmlTextRun]():
            out += "[" + part[XmlTextRun].text + "]"
        elif part.isa[Bold]():
            out += "b(" + part[Bold].text + ")"
        elif part.isa[Italic]():
            out += "i(" + part[Italic].text + ")"
        else:
            ref link = part[MixLink]
            out += "a[" + link.href + "]("
            for inner in link.content:
                if inner.isa[XmlTextRun]():
                    out += "[" + inner[XmlTextRun].text + "]"
                else:
                    out += "b(" + inner[Bold].text + ")"
            out += ")"
    return out^


def test_mixed_content_keeps_document_order() raises:
    var p = from_xml[MixPara]("<p>Hello <b>big</b> and <i>small</i> world</p>")
    assert_equal(_parts(p.content), "[Hello ]b(big)[ and ]i(small)[ world]")


def test_mixed_content_round_trips() raises:
    var doc = String('<p id="x">Hello <b>big</b> and <i>small</i> world</p>')
    var p = from_xml[MixPara](doc.copy())
    assert_equal(p.id.value(), "x")
    assert_equal(to_xml(p), doc)


def test_mixed_text_runs_span_references_cdata_comments_and_pis() raises:
    var p = from_xml[MixPara](
        "<p>a &amp; <![CDATA[<b>]]><!-- c --><?pi x?>z<b>q</b></p>"
    )
    assert_equal(_parts(p.content), "[a & <b>z]b(q)")


def test_mixed_whitespace_runs_are_kept() raises:
    var p = from_xml[MixPara]("<p> <b>x</b>\n</p>")
    assert_equal(_parts(p.content), "[ ]b(x)[\n]")


def test_mixed_empty_content() raises:
    assert_equal(len(from_xml[MixPara]("<p/>").content), 0)
    var p = from_xml[MixPara]('<p id="1"></p>')
    assert_equal(len(p.content), 0)
    assert_equal(p.id.value(), "1")


def test_mixed_content_nests() raises:
    var p = from_xml[MixPara]('<p>see <a href="u">this <b>one</b></a>.</p>')
    assert_equal(_parts(p.content), "[see ]a[u]([this ]b(one))[.]")


def test_mixed_unknown_element_fails() raises:
    assert_fails[MixPara](
        "<p>x<u>y</u></p>", DerErrorKind.UnknownVariant, ".content[1]"
    )


@__annotation(Rename("p"))
@fieldwise_init
struct ElementsOnly(Defaultable, Movable):
    @__annotation(XmlMixed())
    var content: List[Variant[Bold, Italic]]

    def __init__(out self):
        self.content = []


def test_mixed_text_needs_a_text_run_arm() raises:
    assert_equal(
        len(from_xml[ElementsOnly]("<p><b>x</b><i>y</i></p>").content), 2
    )
    assert_fails[ElementsOnly](
        "<p><b>x</b> <i>y</i></p>", DerErrorKind.TypeMismatch, ".content[1]"
    )


@__annotation(Rename("p"), XmlNs("urn:x"))
@fieldwise_init
struct NsPara(Defaultable, Movable):
    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Bold]]

    def __init__(out self):
        self.content = []


def test_mixed_elements_match_by_expanded_name() raises:
    var p = from_xml[NsPara]('<p xmlns="urn:x">t<b>x</b></p>')
    assert_equal(len(p.content), 2)
    assert_fails[NsPara](
        '<p xmlns="urn:x">t<b xmlns="">x</b></p>',
        DerErrorKind.UnknownVariant,
        ".content[1]",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
