# A user-defined `Serializable` impl overrides the reflection-driven default:
# the framework's `serialize` entry point dispatches to `value.serialize(...)`
# whenever `T` conforms to `Serializable`, otherwise it reflects over the fields.

from std.testing import assert_equal, TestSuite
from emberserde.serialize import Serializable, Serializer
from emberserde.error import SerializationError
from _debug_format import debug_string


# Renders as a single tagged string instead of a `{ degrees: N }` struct.
@fieldwise_init
struct Celsius(Copyable, Movable, Serializable):
    var degrees: Int

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(String(self.degrees) + "C")


def test_custom_overrides_reflection() raises:
    # If the reflection default ran instead, this would render as a struct.
    assert_equal(debug_string(Celsius(20)), '"20C"')


def test_custom_inside_list() raises:
    var temps = List[Celsius]()
    temps.append(Celsius(0))
    temps.append(Celsius(100))
    assert_equal(debug_string(temps), '["0C", "100C"]')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
