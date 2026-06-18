from std.memory import ArcPointer, OwnedPointer
from std.testing import assert_equal, TestSuite
from _debug_format import debug_string
from _token_format import to_tokens


@fieldwise_init
struct Point(Copyable, Defaultable, Movable):
    var x: Int
    var y: Int

    def __init__(out self):
        self.x = 0
        self.y = 0


def test_scalar_is_transparent() raises:
    assert_equal(debug_string(OwnedPointer(Int64(5))), "5")
    assert_equal(debug_string(ArcPointer(Int64(5))), "5")
    var v = Int64(5)
    assert_equal(debug_string(Pointer(to=v)), "5")

    assert_equal(debug_string(OwnedPointer(String("hi"))), '"hi"')
    assert_equal(debug_string(ArcPointer(String("hi"))), '"hi"')


def test_struct_is_transparent() raises:
    assert_equal(
        debug_string(OwnedPointer(Point(1, 2))),
        "test_pointers.Point { x: 1, y: 2 }",
    )
    assert_equal(
        debug_string(ArcPointer(Point(1, 2))),
        "test_pointers.Point { x: 1, y: 2 }",
    )
    var p = Point(1, 2)
    assert_equal(
        debug_string(Pointer(to=p)), "test_pointers.Point { x: 1, y: 2 }"
    )


def test_token_stream_has_no_framing() raises:
    assert_equal(to_tokens(OwnedPointer(Int64(7))), to_tokens(Int64(7)))
    assert_equal(to_tokens(ArcPointer(Int64(7))), to_tokens(Int64(7)))
    var p = Point(3, 4)
    assert_equal(to_tokens(Pointer(to=p)), to_tokens(p))
    assert_equal(to_tokens(OwnedPointer(Point(3, 4))), to_tokens(Point(3, 4)))
    assert_equal(to_tokens(ArcPointer(Point(3, 4))), to_tokens(Point(3, 4)))


def test_owned_box_around_collection() raises:
    # A box *around* a collection serializes fine; the limitation is the other
    # way (a collection of non-`Copyable` boxes can't go through the generic
    # `serialize_seq` iterator loop).
    var xs = OwnedPointer([1, 2, 3])
    assert_equal(debug_string(xs), "[1, 2, 3]")


def test_arc_aliasing_is_not_on_the_wire() raises:
    # `b` shares `a`'s allocation (refcount 2), but the wire form can't express
    # that: serialized in a tuple, each side emits a full copy of the pointee.
    var a = ArcPointer(Int64(7))
    var b = a
    assert_equal(a.count(), 2)
    assert_equal(debug_string((a, b)), "(7, 7)")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
