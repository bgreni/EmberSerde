from std.testing import assert_equal, assert_raises, TestSuite
from _json_format import to_json
from _toml_format import TomlDatetime, to_toml
from emberserde.field import Rename


@fieldwise_init
struct Package(Copyable, Movable):
    var name: String
    var version: Int
    var stable: Bool
    var score: Float64
    var published: TomlDatetime


@fieldwise_init
struct Kinds(Copyable, Movable):
    var offset: TomlDatetime
    var local: TomlDatetime
    var date: TomlDatetime
    var time: TomlDatetime


@fieldwise_init
struct Text(Copyable, Movable):
    var s: String


@fieldwise_init
struct Spaced(Copyable, Movable):
    @__annotation(Rename("user name"))
    var user: String


@fieldwise_init
struct Nested(Copyable, Movable):
    var inner: Text


@fieldwise_init
struct Maybe(Copyable, Movable):
    var n: Optional[Int]


@fieldwise_init
struct Big(Copyable, Movable):
    var n: UInt64


def _package() raises -> Package:
    return Package(
        "emberserde", 3, True, 0.5, TomlDatetime.parse("1979-05-27T07:32:00Z")
    )


def test_scalars() raises:
    assert_equal(
        to_toml(_package()),
        (
            'name = "emberserde"\n'
            "version = 3\n"
            "stable = true\n"
            "score = 0.5\n"
            "published = 1979-05-27T07:32:00Z\n"
        ),
    )


def test_datetime_kinds_are_bare_literals() raises:
    var k = Kinds(
        TomlDatetime.parse("1979-05-27T00:32:00.999999-07:00"),
        TomlDatetime.parse("1979-05-27T07:32:00"),
        TomlDatetime.parse("1979-05-27"),
        TomlDatetime.parse("07:32:00.5"),
    )
    assert_equal(
        to_toml(k),
        (
            "offset = 1979-05-27T00:32:00.999999-07:00\n"
            "local = 1979-05-27T07:32:00\n"
            "date = 1979-05-27\n"
            "time = 07:32:00.5\n"
        ),
    )


def test_datetime_is_a_plain_string_in_json() raises:
    assert_equal(
        to_json(_package()),
        (
            '{"name":"emberserde","version":3,"stable":true,"score":0.5,'
            '"published":"1979-05-27T07:32:00Z"}'
        ),
    )


def test_string_escapes() raises:
    assert_equal(
        to_toml(Text('a"b\\c\nd\te\x01é')),
        's = "a\\"b\\\\c\\nd\\te\\u0001é"\n',
    )


def test_key_needing_quotes() raises:
    assert_equal(to_toml(Spaced("ada")), '"user name" = "ada"\n')


def test_root_must_be_a_table() raises:
    with assert_raises(contains="must be a table"):
        _ = to_toml(5)


def test_nested_table_unsupported() raises:
    with assert_raises(contains="unsupported in this TOML subset"):
        _ = to_toml(Nested(Text("x")))


def test_optional_unsupported() raises:
    with assert_raises(contains="unsupported in this TOML subset"):
        _ = to_toml(Maybe(None))


def test_integer_beyond_int64_raises() raises:
    with assert_raises(contains="signed 64-bit"):
        _ = to_toml(Big(UInt64.MAX))


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
