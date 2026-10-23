from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from _csv_format import from_csv
from emberserde.error import DerErrorKind
from emberserde.field import Default, Rename, Skip
from emberserde.struct_modifiers import DenyUnknownFields, RenameAll


@fieldwise_init
struct Person(Copyable, Defaultable, Movable):
    var name: String
    var age: Int
    var active: Bool

    def __init__(out self):
        self.name = String()
        self.age = 0
        self.active = False


@__annotation(RenameAll(.CamelCase))
@fieldwise_init
struct Named(Copyable, Defaultable, Movable):
    var first_name: String

    @__annotation(Rename("years"))
    var age_in_years: Int

    @__annotation(Skip())
    var cache: Int

    def __init__(out self):
        self.first_name = String()
        self.age_in_years = 0
        self.cache = 0


@fieldwise_init
struct Note(Copyable, Defaultable, Movable):
    var text: Optional[String]
    var score: Optional[Int]

    def __init__(out self):
        self.text = None
        self.score = None


@fieldwise_init
struct Filled(Copyable, Defaultable, Movable):
    var name: String
    var note: Optional[String]

    @__annotation(Default(7))
    var level: Int

    def __init__(out self):
        self.name = String()
        self.note = None
        self.level = 0


@__annotation(DenyUnknownFields())
@fieldwise_init
struct Strict(Copyable, Movable):
    var a: Int


@fieldwise_init
struct Small(Copyable, Movable):
    var n: UInt8


@fieldwise_init
struct WithList(Copyable, Defaultable, Movable):
    var label: String
    var xs: List[Int]

    def __init__(out self):
        self.label = String()
        self.xs = []


@fieldwise_init
struct WithPair(Copyable, Defaultable, Movable):
    var label: String
    var pair: Tuple[Int, Int]

    def __init__(out self):
        self.label = String()
        self.pair = (0, 0)


@fieldwise_init
struct Gappy(Copyable, Movable):
    var a: Int

    @__annotation(Skip())
    var gap: Int
    var b: Int
    var c: Int


def _kind_and_path[
    T: Deinitable, has_headers: Bool = True
](s: String) raises -> Tuple[DerErrorKind, String]:
    try:
        _ = from_csv[T, has_headers](s)
    except e:
        return (e.kind, e.path)
    raise Error("expected a DeserializationError")


def test_basic_rows() raises:
    var rows = from_csv[List[Person]](
        "name,age,active\nann,30,true\nbob,41,false\n"
    )
    assert_equal(len(rows), 2)
    assert_equal(rows[0].name, "ann")
    assert_equal(rows[0].age, 30)
    assert_true(rows[0].active)
    assert_equal(rows[1].name, "bob")
    assert_equal(rows[1].age, 41)
    assert_false(rows[1].active)


def test_crlf_and_no_trailing_newline() raises:
    var rows = from_csv[List[Person]](
        "name,age,active\r\nann,30,true\r\nbob,41,false"
    )
    assert_equal(len(rows), 2)
    assert_equal(rows[1].name, "bob")
    assert_false(rows[1].active)


def test_header_binds_wire_names() raises:
    var rows = from_csv[List[Named]]("firstName,years\nann,30\n")
    assert_equal(rows[0].first_name, "ann")
    assert_equal(rows[0].age_in_years, 30)
    assert_equal(rows[0].cache, 0)


def test_quoted_cells() raises:
    var rows = from_csv[List[Note]](
        'text,score\n"a,b",1\n"say ""hi""",2\n"line1\r\nline2",3\n'
    )
    assert_equal(len(rows), 3)
    assert_equal(rows[0].text.value(), "a,b")
    assert_equal(rows[1].text.value(), 'say "hi"')
    assert_equal(rows[2].text.value(), "line1\r\nline2")
    assert_equal(rows[2].score.value(), 3)


def test_optional_cells() raises:
    var rows = from_csv[List[Note]]('text,score\n,\n"",5\n')
    assert_false(Bool(rows[0].text))
    assert_false(Bool(rows[0].score))
    assert_equal(rows[1].text.value(), "")
    assert_equal(rows[1].score.value(), 5)


def test_reordered_columns() raises:
    var rows = from_csv[List[Person]]("active,age,name\ntrue,30,ann\n")
    assert_equal(rows[0].name, "ann")
    assert_equal(rows[0].age, 30)
    assert_true(rows[0].active)


def test_unknown_column_skipped() raises:
    var rows = from_csv[List[Person]](
        'name,extra,age,active\nann,"z,z",30,true\n'
    )
    assert_equal(rows[0].name, "ann")
    assert_equal(rows[0].age, 30)


def test_unknown_column_denied() raises:
    with assert_raises(contains="Unknown field: b"):
        _ = from_csv[List[Strict]]("a,b\n1,2\n")


def test_missing_column_raises() raises:
    var r = _kind_and_path[List[Person]]("name,age\nann,30\n")
    assert_equal(r[0], DerErrorKind.MissingField)
    assert_equal(r[1], "[0]")


def test_missing_columns_filled() raises:
    var rows = from_csv[List[Filled]]("name\nann\n")
    assert_equal(rows[0].name, "ann")
    assert_false(Bool(rows[0].note))
    assert_equal(rows[0].level, 7)


def test_short_row_fills_trailing_columns() raises:
    var rows = from_csv[List[Filled]]("name,note,level\nann,hi,3\nbob\n")
    assert_equal(rows[0].note.value(), "hi")
    assert_equal(rows[0].level, 3)
    assert_equal(rows[1].name, "bob")
    assert_false(Bool(rows[1].note))
    assert_equal(rows[1].level, 7)


def test_number_out_of_range() raises:
    var r = _kind_and_path[List[Small]]("n\n255\n300\n")
    assert_equal(r[0], DerErrorKind.InvalidValue)
    assert_equal(r[1], "[1].n")


def test_error_path_names_row_and_field() raises:
    var r = _kind_and_path[List[Person]](
        "name,age,active\nann,30,true\nbob,x,false\n"
    )
    assert_equal(r[0], DerErrorKind.InvalidValue)
    assert_equal(r[1], "[1].age")


def test_empty_input() raises:
    assert_equal(len(from_csv[List[Person]]("")), 0)
    assert_equal(len(from_csv[List[Person]]("name,age,active\n")), 0)


def test_nested_container_in_cell_raises() raises:
    var r = _kind_and_path[List[WithList]]("label,xs\na,1\n")
    assert_equal(r[0], DerErrorKind.TypeMismatch)
    assert_equal(r[1], "[0].xs")


def test_ragged_row_raises() raises:
    var r = _kind_and_path[List[Person]]("name,age,active\nann,30,true,extra\n")
    assert_equal(r[0], DerErrorKind.InvalidValue)
    assert_equal(r[1], "[0]")


def test_unterminated_quote_raises() raises:
    var r = _kind_and_path[List[Note]]('text,score\n"abc,1\n')
    assert_equal(r[0], DerErrorKind.InvalidValue)


def test_tuple_in_cell_raises() raises:
    var r = _kind_and_path[List[WithPair], has_headers=False]("a,1\n")
    assert_equal(r[0], DerErrorKind.TypeMismatch)
    assert_equal(r[1], "[0].pair")


def test_tuple_rows_headerless() raises:
    var rows = from_csv[List[Tuple[Int, String]], has_headers=False](
        '1,a\r\n2,"b,c"\n'
    )
    assert_equal(len(rows), 2)
    assert_equal(rows[0][0], 1)
    assert_equal(rows[0][1], "a")
    assert_equal(rows[1][0], 2)
    assert_equal(rows[1][1], "b,c")


def test_headered_file_into_tuples() raises:
    var rows = from_csv[List[Tuple[Int, String]]]("id,name\n1,a\n")
    assert_equal(len(rows), 1)
    assert_equal(rows[0][0], 1)
    assert_equal(rows[0][1], "a")


def test_struct_rows_headerless() raises:
    var rows = from_csv[List[Named], has_headers=False]("ann,30\nbob,41\n")
    assert_equal(len(rows), 2)
    assert_equal(rows[1].first_name, "bob")
    assert_equal(rows[1].age_in_years, 41)
    assert_equal(rows[1].cache, 0)


def test_headerless_struct_steps_over_skipped_fields() raises:
    var rows = from_csv[List[Gappy], has_headers=False]("1,2,3\n")
    assert_equal(rows[0].a, 1)
    assert_equal(rows[0].gap, 0)
    assert_equal(rows[0].b, 2)
    assert_equal(rows[0].c, 3)


def test_struct_rows_headerless_too_many_cells() raises:
    var r = _kind_and_path[List[Gappy], has_headers=False]("1,2,3,4\n")
    assert_equal(r[0], DerErrorKind.InvalidValue)
    assert_equal(r[1], "[0]")


def test_tuple_arity_mismatch() raises:
    comptime Pair = List[Tuple[Int, String]]
    var long = _kind_and_path[Pair, has_headers=False]("1,a,x\n")
    assert_equal(long[0], DerErrorKind.InvalidValue)
    assert_equal(long[1], "[0][2]")
    var short = _kind_and_path[Pair, has_headers=False]("1,a\n2\n")
    assert_equal(short[0], DerErrorKind.InvalidValue)
    assert_equal(short[1], "[1][1]")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
