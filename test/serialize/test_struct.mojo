from std.testing import assert_equal, TestSuite
from emberserde.serialize import Serializable, Serializer
from emberserde.error import SerializationError
from _debug_format import debug_string


@fieldwise_init
struct Record(Copyable, Movable):
    var id: Int
    var name: String
    var active: Bool


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


@fieldwise_init
struct Celsius(Copyable, Movable, Serializable):
    var degrees: Int

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(String(self.degrees) + "C")


def test_reflection_default_renders_all_fields() raises:
    assert_equal(
        debug_string(Record(7, "ada", True)),
        'test_struct.Record { id: 7, name: "ada", active: true }',
    )
    assert_equal(
        debug_string(Record(1, "x", False)),
        'test_struct.Record { id: 1, name: "x", active: false }',
    )


def test_nested_struct() raises:
    assert_equal(
        debug_string(Outer("top", Inner(99))),
        (
            'test_struct.Outer { label: "top", inner:'
            " test_struct.Inner { v: 99 } }"
        ),
    )


def test_list_of_struct() raises:
    var items = List[Inner]()
    items.append(Inner(1))
    items.append(Inner(2))
    assert_equal(
        debug_string(items),
        "[test_struct.Inner { v: 1 }, test_struct.Inner { v: 2 }]",
    )


def test_optional_field_some_and_none() raises:
    assert_equal(
        debug_string(WithOpt(Optional(Int64(3)))),
        "test_struct.WithOpt { maybe: Some(3) }",
    )
    assert_equal(
        debug_string(WithOpt(Optional[Int64](None))),
        "test_struct.WithOpt { maybe: None }",
    )


def test_custom_impl_overrides_reflection() raises:
    # If the reflection default ran instead, this would render as a struct.
    assert_equal(debug_string(Celsius(20)), '"20C"')


def test_custom_impl_inside_list() raises:
    var temps = List[Celsius]()
    temps.append(Celsius(0))
    temps.append(Celsius(100))
    assert_equal(debug_string(temps), '["0C", "100C"]')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
