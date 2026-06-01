# Serialize a plain struct via the reflection-driven default (`_default_serialize`).
#
# The rendered struct name is module-qualified with this file's module stem
# (`test_struct_reflection`), so the full expected strings include that prefix.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


@fieldwise_init
struct Record(Copyable, Movable):
    var id: Int
    var name: String
    var active: Bool


def test_all_fields_rendered() raises:
    assert_equal(
        debug_string(Record(7, "ada", True)),
        'test_struct_reflection.Record { id: 7, name: "ada", active: true }',
    )


def test_field_order_and_framing() raises:
    # Exact string also pins comma/space placement and declaration order.
    assert_equal(
        debug_string(Record(1, "x", False)),
        'test_struct_reflection.Record { id: 1, name: "x", active: false }',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
