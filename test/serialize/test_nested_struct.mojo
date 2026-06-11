# Serialize composites: struct-within-struct, list-of-struct, and a struct with
# an `Optional` field, all via the reflection-driven default.
#
# Struct names are module-qualified with this file's module stem
# (`test_nested_struct`), so the full expected strings include that prefix.

from std.testing import assert_equal, TestSuite
from _debug_format import debug_string


@fieldwise_init
struct Inner(Copyable, Movable):
    var v: Int


@fieldwise_init
struct Outer(Copyable, Movable):
    var label: String
    var inner: Inner


@fieldwise_init
struct WithOpt(Copyable, Movable):
    var maybe: Optional[Int64]


def test_struct_in_struct() raises:
    assert_equal(
        debug_string(Outer("top", Inner(99))),
        (
            'test_nested_struct.Outer { label: "top", inner:'
            " test_nested_struct.Inner { v: 99 } }"
        ),
    )


def test_list_of_struct() raises:
    var items = List[Inner]()
    items.append(Inner(1))
    items.append(Inner(2))
    assert_equal(
        debug_string(items),
        (
            "[test_nested_struct.Inner { v: 1 },"
            " test_nested_struct.Inner { v: 2 }]"
        ),
    )


def test_struct_with_some() raises:
    assert_equal(
        debug_string(WithOpt(Optional(Int64(3)))),
        "test_nested_struct.WithOpt { maybe: Some(3) }",
    )


def test_struct_with_none() raises:
    assert_equal(
        debug_string(WithOpt(Optional[Int64](None))),
        "test_nested_struct.WithOpt { maybe: None }",
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
