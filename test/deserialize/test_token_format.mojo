from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    TestSuite,
)
from _token_format import from_tokens


@fieldwise_init
struct Record(Copyable, Defaultable, Movable):
    var id: Int
    var name: String
    var active: Bool
    var note: Optional[Int64]

    def __init__(out self):
        self.id = 0
        self.name = String()
        self.active = False
        self.note = None


@fieldwise_init
struct Outer(Copyable, Defaultable, Movable):
    var label: String
    var inner: Record

    def __init__(out self):
        self.label = String()
        self.inner = Record()


def test_primitives() raises:
    assert_equal(from_tokens[Int](["42"]), 42)
    assert_equal(from_tokens[Bool](["true"]), True)
    assert_equal(from_tokens[Float64](["2.5"]), 2.5)
    assert_equal(from_tokens[String](["hi there"]), String("hi there"))


def test_list() raises:
    var r = from_tokens[List[Int]](["3", "10", "20", "30"])
    assert_equal(len(r), 3)
    assert_equal(r[0], 10)
    assert_equal(r[1], 20)
    assert_equal(r[2], 30)


def test_optional() raises:
    # Present: `1` presence tag then the payload.
    var some = from_tokens[Optional[Int64]](["1", "5"])
    assert_true(Bool(some))
    assert_equal(some.value(), Int64(5))

    # Empty: just the `0` tag.
    var none = from_tokens[Optional[Int64]](["0"])
    assert_false(Bool(none))


def test_struct() raises:
    var r = from_tokens[Record](["7", "ada", "true", "1", "9"])
    assert_equal(r.id, 7)
    assert_equal(r.name, String("ada"))
    assert_equal(r.active, True)
    assert_true(Bool(r.note))
    assert_equal(r.note.value(), Int64(9))


def test_struct_with_empty_optional() raises:
    var r = from_tokens[Record](["1", "x", "false", "0"])
    assert_equal(r.id, 1)
    assert_false(Bool(r.note))


def test_nested_struct() raises:
    var r = from_tokens[Outer](["top", "3", "n", "true", "0"])
    assert_equal(r.label, String("top"))
    assert_equal(r.inner.id, 3)
    assert_equal(r.inner.name, String("n"))
    assert_equal(r.inner.active, True)
    assert_false(Bool(r.inner.note))


def test_list_of_struct() raises:
    var r = from_tokens[List[Record]](
        ["2", "1", "a", "true", "0", "2", "b", "false", "1", "4"]
    )
    assert_equal(len(r), 2)
    assert_equal(r[0].id, 1)
    assert_equal(r[1].id, 2)
    assert_true(Bool(r[1].note))
    assert_equal(r[1].note.value(), Int64(4))


def test_dict() raises:
    var r = from_tokens[Dict[String, Int]](["2", "a", "1", "b", "2"])
    assert_equal(len(r), 2)
    assert_equal(r["a"], 1)
    assert_equal(r["b"], 2)


def test_tuple() raises:
    var r = from_tokens[Tuple[Int, String, Bool]](["7", "ada", "true"])
    assert_equal(r[0], 7)
    assert_equal(r[1], String("ada"))
    assert_equal(r[2], True)


def test_nested_tuple() raises:
    var r = from_tokens[Tuple[Int, Tuple[String, Int64]]](["1", "x", "2"])
    assert_equal(r[0], 1)
    assert_equal(r[1][0], String("x"))
    assert_equal(r[1][1], Int64(2))


def test_truncated_stream_raises() raises:
    # A 3-element count followed by only two values: the reader runs off the
    # end of the stream with nothing on the wire to stop it early.
    var truncated: List[String] = ["3", "10", "20"]
    var raised = False
    try:
        _ = from_tokens[List[Int]](truncated^)
    except e:
        raised = True
    assert_true(raised)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
