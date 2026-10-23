from std.testing import assert_equal, assert_raises, TestSuite
from _csv_format import to_csv
from emberserde.field import Rename, Skip
from emberserde.struct_modifiers import RenameAll


@fieldwise_init
struct Person(Copyable, Movable):
    var name: String
    var age: Int
    var active: Bool


@__annotation(RenameAll(.CamelCase))
@fieldwise_init
struct Named(Copyable, Movable):
    var first_name: String

    @__annotation(Rename("years"))
    var age_in_years: Int

    @__annotation(Skip())
    var cache: Int


@fieldwise_init
struct Note(Copyable, Movable):
    var text: Optional[String]
    var score: Optional[Int]


@fieldwise_init
struct Point(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct WithPoint(Copyable, Movable):
    var label: String
    var point: Point


@fieldwise_init
struct WithList(Copyable, Movable):
    var label: String
    var xs: List[Int]


@fieldwise_init
struct WithPair(Copyable, Movable):
    var label: String
    var pair: Tuple[Int, Int]


def test_basic_rows() raises:
    var rows: List[Person] = [Person("ann", 30, True), Person("bob", 41, False)]
    assert_equal(to_csv(rows), "name,age,active\nann,30,true\nbob,41,false\n")


def test_header_from_wire_names() raises:
    var rows: List[Named] = [Named("ann", 30, 99)]
    assert_equal(to_csv(rows), "firstName,years\nann,30\n")


def test_quoting() raises:
    var rows: List[Note] = [
        Note(String("a,b"), None),
        Note(String('say "hi"'), None),
        Note(String("line1\nline2"), None),
        Note(String("cr\rhere"), None),
    ]
    assert_equal(
        to_csv(rows),
        'text,score\n"a,b",\n"say ""hi""",\n"line1\nline2",\n"cr\rhere",\n',
    )


def test_optional_cells() raises:
    var rows: List[Note] = [
        Note(None, None),
        Note(String(""), Int(0)),
        Note(String("x"), Int(5)),
    ]
    assert_equal(to_csv(rows), 'text,score\n,\n"",0\nx,5\n')


def test_empty_input_writes_nothing() raises:
    assert_equal(to_csv(List[Person]()), "")


def test_nested_container_in_cell_raises() raises:
    var points: List[WithPoint] = [WithPoint("a", Point(1, 2))]
    with assert_raises(contains="cannot hold a nested container"):
        _ = to_csv(points)
    var lists: List[WithList] = [WithList("a", [1, 2])]
    with assert_raises(contains="cannot hold a nested container"):
        _ = to_csv(lists)


def test_tuple_in_cell_raises() raises:
    var rows: List[WithPair] = [WithPair("a", (1, 2))]
    with assert_raises(contains="cannot hold a nested container"):
        _ = to_csv[has_headers=False](rows)


def test_tuple_rows_headerless() raises:
    var rows: List[Tuple[Int, String]] = [(1, "a"), (2, "b,c")]
    assert_equal(to_csv[has_headers=False](rows), '1,a\n2,"b,c"\n')


def test_struct_rows_headerless() raises:
    var rows: List[Named] = [Named("ann", 30, 99)]
    assert_equal(to_csv[has_headers=False](rows), "ann,30\n")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
