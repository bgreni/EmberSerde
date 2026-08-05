from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)
from emberserde.deserialize import Deserializer, Deserializable
from emberserde.error import DeserializationError, DerErrorKind
from _debug_format import from_debug


@fieldwise_init
struct Point(Copyable, Defaultable, Deserializable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_struct[Self]()


@fieldwise_init
struct Record(Copyable, Defaultable, Deserializable, Movable):
    var id: Int
    var name: String
    var active: Bool

    def __init__(out self):
        self.id = 0
        self.name = String()
        self.active = False

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return d.expect_struct[Self]()


@fieldwise_init
struct Pair(Copyable, Movable):
    var x: Int
    var y: Int


@fieldwise_init
struct WithOpt(Copyable, Defaultable, Movable):
    var id: Int
    var note: Optional[Int64]

    def __init__(out self):
        self.id = 0
        self.note = None


def test_struct_fields() raises:
    var p = from_debug[Point]("Point { x: 1, y: 2 }")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_struct_inside_list() raises:
    var r = from_debug[List[Point]](
        "[Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]"
    )
    assert_equal(len(r), 2)
    assert_equal(r[0].x, 1)
    assert_equal(r[0].y, 2)
    assert_equal(r[1].x, 3)
    assert_equal(r[1].y, 4)


def test_fields_matched_by_name_not_position() raises:
    var p = from_debug[Point]("Pt { y: 20, x: 10 }")
    assert_equal(p.x, 10)
    assert_equal(p.y, 20)

    var r = from_debug[Record]('Rec { name: "ada", active: true, id: 7 }')
    assert_equal(r.id, 7)
    assert_equal(r.name, String("ada"))
    assert_equal(r.active, True)


def test_unknown_field_skipped() raises:
    var p = from_debug[Pair]("P { x: 1, junk: 99, y: 2 }")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_unknown_nested_field_skipped() raises:
    # The skipped value contains nested braces, brackets, and a string with
    # separators in it — `skip_value` must consume it as one balanced unit.
    var p = from_debug[Pair](
        'P { junk: Foo { a: [1, 2], b: "x,y}" }, x: 1, y: 2 }'
    )
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_unknown_field_skipped_then_missing_raises() raises:
    # `z` is unknown and gets skipped; the raise is for the absent `y`.
    with assert_raises():
        _ = from_debug[Point]("Pt { x: 1, z: 2 }")


def test_duplicate_field_raises() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[Pair]("P { x: 1, x: 2, y: 3 }")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.DuplicateField)


def test_missing_field_raises() raises:
    var kind = DerErrorKind.Custom
    try:
        _ = from_debug[Pair]("P { x: 1 }")
    except e:
        kind = e.kind
    assert_equal(kind, DerErrorKind.MissingField)


@fieldwise_init
struct Nest(Copyable, Defaultable, Movable):
    var label: String
    var inner: Pair

    def __init__(out self):
        self.label = String()
        self.inner = Pair(0, 0)


struct Unit(Copyable, Defaultable, Movable):
    def __init__(out self):
        pass


def test_zero_field_struct() raises:
    _ = from_debug[Unit]("Unit { }")


# The classic recursion stress case. `Optional[OwnedPointer[Self]]` does not
# compile today ("struct has recursive reference to itself" through
# `Optional`'s inline storage; wrapper indirection dies on the
# conformance-inference cycle instead), so the recursion vehicle is
# `List[Self]` — same shape `JsonValue` uses via `JsonArray`.
@fieldwise_init
struct TreeNode(Copyable, Defaultable, Movable):
    var value: Int
    var kids: List[TreeNode]

    def __init__(out self):
        self.value = 0
        self.kids = List[TreeNode]()

    # Explicit (empty) destructor breaks the deletability-inference cycle a
    # self-referential field creates; fields are still destroyed after it.
    def __deinit__(deinit self):
        pass


def test_recursive_struct() raises:
    var r = from_debug[TreeNode](
        "T { value: 1, kids: [T { value: 2, kids: [] }] }"
    )
    assert_equal(r.value, 1)
    assert_equal(len(r.kids), 1)
    assert_equal(r.kids[0].value, 2)
    assert_equal(len(r.kids[0].kids), 0)


def test_error_path_nested_field() raises:
    # A bad value two levels down: each descent site prepends its segment on
    # the unwind, spelling out `.inner.y`.
    var path = String("unset")
    try:
        _ = from_debug[Nest]('N { label: "l", inner: P { x: 1, y: oops } }')
    except e:
        path = e.path
    assert_equal(path, ".inner.y")


def test_missing_optional_field_defaults_to_none() raises:
    var w = from_debug[WithOpt]("W { id: 7 }")
    assert_equal(w.id, 7)
    assert_false(Bool(w.note))


def test_optional_field_present() raises:
    var w = from_debug[WithOpt]("W { id: 7, note: Some(9) }")
    assert_equal(w.id, 7)
    assert_true(Bool(w.note))
    assert_equal(w.note.value(), Int64(9))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
