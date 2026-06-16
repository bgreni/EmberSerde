# Pointer types round-trip transparently. Because nothing frames the value on
# the wire (a pointer serializes as its bare pointee), reconstruction is always
# "deserialize the pointee, then wrap it":
#
#   * `OwnedPointer` (serde's `Box<T>`)   — box the deserialized value
#   * `ArcPointer`   (serde's `Rc`/`Arc`) — wrap in a fresh allocation; the
#       rebuilt pointer starts at refcount 1, so any aliasing that existed
#       before serialization is gone (the wire never carried it)
#
# `Pointer` (a safe borrow) has no `Deserializable` counterpart — there is no
# owned storage to point at — so it is serialize-only and absent here.
#
# Tests are grouped by behaviour, not by pointer type. `from_tokens` rebuilds
# from a hand-written, shape-less token stream; `from_debug` round-trips
# through the self-describing debug format.

from std.memory import ArcPointer, OwnedPointer
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string, from_debug
from _token_format import from_tokens, to_tokens


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


def test_scalar_from_tokens() raises:
    # No framing: a bare value token deserializes straight into the pointer.
    assert_equal(from_tokens[OwnedPointer[Int64]](["5"])[], Int64(5))

    var arc = from_tokens[ArcPointer[Int64]](["5"])
    assert_equal(arc[], Int64(5))
    assert_equal(arc.count(), 1)  # rebuilt pointers start unshared


def test_string_from_tokens() raises:
    assert_equal(from_tokens[OwnedPointer[String]](["hi"])[], String("hi"))
    assert_equal(from_tokens[ArcPointer[String]](["hi"])[], String("hi"))


def test_struct_from_tokens() raises:
    var boxed = from_tokens[OwnedPointer[Point]](["3", "4"])
    assert_equal(boxed[].x, 3)
    assert_equal(boxed[].y, 4)

    var arc = from_tokens[ArcPointer[Point]](["3", "4"])
    assert_equal(arc[].x, 3)
    assert_equal(arc[].y, 4)


def test_debug_round_trip() raises:
    var boxed = from_debug[OwnedPointer[Int64]](
        debug_string(OwnedPointer(Int64(42)))
    )
    assert_equal(boxed[], Int64(42))

    var arc = from_debug[ArcPointer[Int64]](debug_string(ArcPointer(Int64(42))))
    assert_equal(arc[], Int64(42))


def test_token_round_trip() raises:
    var boxed = from_tokens[OwnedPointer[Point]](
        to_tokens(OwnedPointer(Point(7, 9)))
    )
    assert_equal(boxed[].x, 7)
    assert_equal(boxed[].y, 9)

    var arc = from_tokens[ArcPointer[Point]](to_tokens(ArcPointer(Point(7, 9))))
    assert_equal(arc[].x, 7)
    assert_equal(arc[].y, 9)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
