import emberserde
from std.testing import assert_equal, TestSuite
from _token_format import to_tokens


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


def assert_tokens(actual: List[String], expected: List[String]) raises:
    assert_equal(len(actual), len(expected))
    for i in range(len(expected)):
        assert_equal(actual[i], expected[i])


def test_primitives() raises:
    assert_tokens(to_tokens(42), ["42"])
    assert_tokens(to_tokens(True), ["true"])
    assert_tokens(to_tokens(Float64(2.5)), ["2.5"])
    assert_tokens(to_tokens(String("hi there")), ["hi there"])


def test_list_wire_form() raises:
    # The element count is written up front (from the begin_seq size hint):
    # nothing else on the wire marks where the sequence ends.
    var xs: List[Int] = [10, 20, 30]
    assert_tokens(to_tokens(xs), ["3", "10", "20", "30"])


def test_optional_wire_form() raises:
    # Present: `1` presence tag (from serialize_some) then the payload.
    assert_tokens(to_tokens(Optional(Int64(5))), ["1", "5"])
    # Empty: just the `0` tag.
    assert_tokens(to_tokens(Optional[Int64](None)), ["0"])


def test_struct_wire_form() raises:
    # No field names on the wire: 1 id + 1 name + 1 active + 2 note tokens.
    var rec = Record(7, String("ada"), True, Optional(Int64(9)))
    assert_tokens(to_tokens(rec), ["7", "ada", "true", "1", "9"])


def test_struct_with_empty_optional() raises:
    var rec = Record(1, String("x"), False, Optional[Int64](None))
    assert_tokens(to_tokens(rec), ["1", "x", "false", "0"])


def test_nested_struct_wire_form() raises:
    var o = Outer(String("top"), Record(3, String("n"), True, None))
    assert_tokens(to_tokens(o), ["top", "3", "n", "true", "0"])


def test_list_of_struct_wire_form() raises:
    var xs = List[Record]()
    xs.append(Record(1, String("a"), True, None))
    xs.append(Record(2, String("b"), False, Optional(Int64(4))))
    assert_tokens(
        to_tokens(xs),
        ["2", "1", "a", "true", "0", "2", "b", "false", "1", "4"],
    )


def test_dict_wire_form() raises:
    # Entry count + 2 tokens per entry.
    var d = {"a": 1, "b": 2}
    assert_tokens(to_tokens(d), ["2", "a", "1", "b", "2"])


def test_tuple_wire_form() raises:
    # A tuple's arity is comptime-known on both ends, so — unlike a seq —
    # nothing framing-related is written: just one token per element.
    var t = (7, String("ada"), True)
    assert_tokens(to_tokens(t), ["7", "ada", "true"])


def test_nested_tuple_wire_form() raises:
    var t = (1, (String("x"), Int64(2)))
    assert_tokens(to_tokens(t), ["1", "x", "2"])


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
