from std.testing import assert_equal, assert_raises, TestSuite
from std.utils import Variant
from _xml_format import (
    from_xml,
    to_xml,
    XmlAttr,
    XmlMixed,
    XmlNs,
    XmlText,
    XmlTextRun,
)
from emberserde.error import SerializationError
from emberserde.field import Rename, Skip
from emberserde.serialize import Serializable, Serializer
from emberserde.struct_modifiers import RenameAll, arm_tag


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@__annotation(Rename("pt"))
@fieldwise_init
struct Renamed(Movable):
    var x: Int


@fieldwise_init
struct Empty(Movable):
    pass


def test_primitives() raises:
    assert_equal(to_xml(5), "<value>5</value>")
    assert_equal(to_xml(Int64(-3)), "<value>-3</value>")
    assert_equal(to_xml(1.5), "<value>1.5</value>")
    assert_equal(to_xml(True), "<value>true</value>")
    assert_equal(to_xml(String("hi")), "<value>hi</value>")
    assert_equal(to_xml(String("")), "<value/>")


def test_text_escapes() raises:
    assert_equal(
        to_xml(String("a <b> & \"c\" 'd'")),
        "<value>a &lt;b&gt; &amp; \"c\" 'd'</value>",
    )


def test_struct_root_name() raises:
    assert_equal(to_xml(Point(1, 2)), "<Point><x>1</x><y>2</y></Point>")
    assert_equal(to_xml(Renamed(3)), "<pt><x>3</x></pt>")
    assert_equal(to_xml(Empty()), "<Empty/>")


@fieldwise_init
struct Line(Movable):
    var a: Point
    var b: Point


def test_nested_struct() raises:
    assert_equal(
        to_xml(Line(Point(1, 2), Point(3, 4))),
        "<Line><a><x>1</x><y>2</y></a><b><x>3</x><y>4</y></b></Line>",
    )


@fieldwise_init
struct Link(Movable):
    @__annotation(XmlAttr())
    var href: String

    @__annotation(XmlText())
    var label: String

    @__annotation(XmlAttr())
    var rel: Optional[String]


def test_attributes_and_text() raises:
    assert_equal(
        to_xml(Link('/a?x=1&y="2"', "Home & away", None)),
        '<Link href="/a?x=1&amp;y=&quot;2&quot;">Home &amp; away</Link>',
    )
    assert_equal(
        to_xml(Link("/", "", String("next"))), '<Link href="/" rel="next"/>'
    )


# An attribute declared after a child still lands in the start tag.
@fieldwise_init
struct Late(Movable):
    var child: Int

    @__annotation(XmlAttr())
    var id: Int


def test_attribute_after_child_field() raises:
    assert_equal(to_xml(Late(1, 7)), '<Late id="7"><child>1</child></Late>')


@fieldwise_init
struct Feed(Movable):
    var title: String
    var item: List[String]


def test_unwrapped_list() raises:
    assert_equal(
        to_xml(Feed("t", ["a", "b"])),
        "<Feed><title>t</title><item>a</item><item>b</item></Feed>",
    )
    assert_equal(to_xml(Feed("t", [])), "<Feed><title>t</title></Feed>")


@fieldwise_init
struct Grid(Movable):
    var row: List[List[Int]]


def test_nested_list_is_boxed() raises:
    assert_equal(
        to_xml(Grid([[1, 2], []])),
        "<Grid><row><item>1</item><item>2</item></row><row></row></Grid>",
    )
    assert_equal(to_xml([1, 2]), "<value><item>1</item><item>2</item></value>")


@fieldwise_init
struct Env(Movable):
    var vars: Dict[String, Int]


def test_map() raises:
    var d = Dict[String, Int]()
    d["a"] = 1
    d["b"] = 2
    assert_equal(
        to_xml(Env(d.copy())),
        (
            "<Env><vars><key>a</key><value>1</value></vars>"
            "<vars><key>b</key><value>2</value></vars></Env>"
        ),
    )
    assert_equal(
        to_xml(d),
        (
            "<value><entry><key>a</key><value>1</value></entry>"
            "<entry><key>b</key><value>2</value></entry></value>"
        ),
    )


def test_tuple() raises:
    assert_equal(
        to_xml(Tuple[Int, String](1, "x")),
        "<value><item>1</item><item>x</item></value>",
    )


@fieldwise_init
struct Opt(Movable):
    var a: Optional[Int]
    var xs: List[Optional[Int]]


def test_optional() raises:
    assert_equal(to_xml(Opt(None, [])), "<Opt/>")
    assert_equal(
        to_xml(Opt(0, [Optional[Int](1), None])),
        '<Opt><a>0</a><xs>1</xs><xs nil="true"/></Opt>',
    )
    assert_equal(to_xml(Optional[Int]()), '<value nil="true"/>')


@__annotation(Rename("circle"))
@fieldwise_init
struct Circle(Copyable, Movable):
    @__annotation(XmlAttr())
    var r: Int


@fieldwise_init
struct Scene(Movable):
    var shape: Variant[Circle, Int64]


def test_variant() raises:
    assert_equal(
        to_xml(Scene(Variant[Circle, Int64](Circle(2)))),
        '<Scene><shape variant="circle" r="2"/></Scene>',
    )
    assert_equal(
        to_xml(Variant[Circle, Int64](Int64(5))),
        String(t'<value variant="{arm_tag[Int64]()}">5</value>'),
    )


@fieldwise_init
struct ByteBuf(Movable, Serializable):
    var data: List[Byte]

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bytes(Span(self.data))


def test_bytes() raises:
    assert_equal(to_xml(ByteBuf([0, 15, 255])), "<value>000fff</value>")


@__annotation(RenameAll(.CamelCase))
@fieldwise_init
struct Annotated(Movable):
    var first_name: String

    @__annotation(Skip())
    var cache: Int

    @__annotation(Rename("n"))
    var count: Int


def test_framework_annotations() raises:
    assert_equal(
        to_xml(Annotated("Ann", 9, 2)),
        "<Annotated><firstName>Ann</firstName><n>2</n></Annotated>",
    )


@fieldwise_init
struct BadAttr(Movable):
    @__annotation(XmlAttr())
    var p: Point


def test_struct_attribute_rejected() raises:
    with assert_raises():
        _ = to_xml(BadAttr(Point(1, 2)))


@fieldwise_init
struct Spacey(Defaultable, Movable):
    @__annotation(XmlAttr())
    var a: String

    @__annotation(XmlText())
    var t: String

    def __init__(out self):
        self.a = ""
        self.t = ""


# Line-end and attribute-value normalization would otherwise rewrite
# these on the way back in.
def test_whitespace_escaped_to_round_trip() raises:
    var out = to_xml(Spacey("x\ty\nz\r", "a\rb\r\nc ]]> d"))
    assert_equal(
        out, '<Spacey a="x&#9;y&#10;z&#13;">a&#13;b&#13;\nc ]]&gt; d</Spacey>'
    )
    var back = from_xml[Spacey](out)
    assert_equal(back.a, "x\ty\nz\r")
    assert_equal(back.t, "a\rb\r\nc ]]> d")


def test_unrepresentable_characters_raise() raises:
    with assert_raises():
        _ = to_xml(String("a\x01b"))
    with assert_raises():
        _ = to_xml(String("￾"))


@fieldwise_init
struct BadName(Movable):
    @__annotation(Rename("1st"))
    var first: Int


@fieldwise_init
struct Prefixed(Movable):
    @__annotation(Rename("a:b"))
    var x: Int


def test_invalid_names_raise() raises:
    with assert_raises():
        _ = to_xml(BadName(1))
    with assert_raises():
        _ = to_xml(Prefixed(1))


@__annotation(XmlNs("urn:p"))
@fieldwise_init
struct NsPoint(Copyable, Movable):
    var x: Int

    @__annotation(XmlNs("urn:o"))
    var y: Int

    @__annotation(XmlAttr(), XmlNs("urn:a"))
    var tag: Int

    @__annotation(XmlAttr())
    var plain: Int

    var inner: Point


def test_namespaces_declared_where_they_change() raises:
    var out = to_xml(NsPoint(1, 2, 3, 4, Point(5, 6)))
    assert_equal(
        out,
        (
            '<NsPoint xmlns="urn:p" xmlns:ns0="urn:a" ns0:tag="3" plain="4">'
            '<x>1</x><y xmlns="urn:o">2</y><inner><x xmlns="">5</x>'
            '<y xmlns="">6</y></inner></NsPoint>'
        ),
    )
    var back = from_xml[NsPoint](out)
    assert_equal(back.y, 2)
    assert_equal(back.tag, 3)
    assert_equal(back.inner.y, 6)


@__annotation(Rename("b"))
@fieldwise_init
struct Bold(Copyable, Movable):
    @__annotation(XmlText())
    var text: String


@__annotation(Rename("p"))
@fieldwise_init
struct Para(Movable):
    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Bold]]


def test_mixed_content_is_written_in_order() raises:
    var content: List[Variant[XmlTextRun, Bold]] = [
        XmlTextRun("1 < 2 "),
        Bold("&"),
        XmlTextRun(" done"),
    ]
    assert_equal(to_xml(Para(content^)), "<p>1 &lt; 2 <b>&amp;</b> done</p>")


@__annotation(Rename("p"))
@fieldwise_init
struct BadArm(Movable):
    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Int64]]


# An arm's tag names its element, and `SIMD[DType.int64, 1]` can't.
def test_mixed_element_arm_needs_an_xml_name() raises:
    var content: List[Variant[XmlTextRun, Int64]] = [Int64(1)]
    with assert_raises(contains="needs a struct Rename"):
        _ = to_xml(BadArm(content^))


@__annotation(Rename("p"), XmlNs("urn:x"))
@fieldwise_init
struct NsPara(Movable):
    @__annotation(XmlMixed())
    var content: List[Variant[XmlTextRun, Bold]]


def test_mixed_elements_take_the_field_namespace() raises:
    var content: List[Variant[XmlTextRun, Bold]] = [
        XmlTextRun("t"),
        Bold("x"),
    ]
    assert_equal(to_xml(NsPara(content^)), '<p xmlns="urn:x">t<b>x</b></p>')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
