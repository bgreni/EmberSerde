# A plain struct opts into deserialization with a one-line `Deserializable` impl
# that routes through the reflection-driven `expect_struct` default — the dual of
# the reflection-driven `serialize_struct`. Inputs are hand-written debug-format
# literals (not produced by the serializer) so the assertion pins the actual wire
# form. `Defaultable` is required because `expect_struct` builds the value before
# filling its fields. Counterpart of `test_custom_impl.mojo`.

from std.testing import assert_equal, assert_raises, TestSuite
from emberserde.deserialize import Deserializer, Deserializable
from emberserde.error import DeserializationError
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


# Heterogeneous fields make name-vs-position matching observable: read
# positionally, `id` would try to parse `"ada"` and `active` would mismatch.
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


def test_struct_fields() raises:
    var p = from_debug[Point]("Point { x: 1, y: 2 }")
    assert_equal(p.x, 1)
    assert_equal(p.y, 2)


def test_struct_inside_list() raises:
    # A struct nested in a sequence exercises recursion through both framings.
    var r = from_debug[List[Point]](
        "[Point { x: 1, y: 2 }, Point { x: 3, y: 4 }]"
    )
    assert_equal(len(r), 2)
    assert_equal(r[0].x, 1)
    assert_equal(r[0].y, 2)
    assert_equal(r[1].x, 3)
    assert_equal(r[1].y, 4)


def test_struct_field_order_independent() raises:
    # Keys in reverse declaration order must map by name, not position.
    var p = from_debug[Point]("Pt { y: 20, x: 10 }")
    assert_equal(p.x, 10)
    assert_equal(p.y, 20)


def test_struct_mixed_types_reordered() raises:
    # Scrambled keys with distinct field types: positional reading would
    # mis-pair the values and the types wouldn't line up.
    var r = from_debug[Record]('Rec { name: "ada", active: true, id: 7 }')
    assert_equal(r.id, 7)
    assert_equal(r.name, String("ada"))
    assert_equal(r.active, True)


def test_unknown_field_skipped_missing_raises() raises:
    # `z` is unknown and gets skipped; the raise is for the absent `y`.
    with assert_raises():
        _ = from_debug[Point]("Pt { x: 1, z: 2 }")


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
