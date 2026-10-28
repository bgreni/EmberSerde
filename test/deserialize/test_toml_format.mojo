from std.testing import (
    assert_equal,
    assert_false,
    assert_raises,
    assert_true,
    TestSuite,
)
from _json_format import from_json
from _toml_format import TomlDatetime, from_toml
from emberserde.error import DerErrorKind
from emberserde.field import Rename


@fieldwise_init
struct Package(Copyable, Defaultable, Movable):
    var name: String
    var version: Int
    var stable: Bool
    var score: Float64
    var published: TomlDatetime

    def __init__(out self):
        self.name = String()
        self.version = 0
        self.stable = False
        self.score = 0.0
        self.published = TomlDatetime()


@fieldwise_init
struct Kinds(Copyable, Defaultable, Movable):
    var offset: TomlDatetime
    var local: TomlDatetime
    var date: TomlDatetime
    var time: TomlDatetime

    def __init__(out self):
        self.offset = TomlDatetime()
        self.local = TomlDatetime()
        self.date = TomlDatetime()
        self.time = TomlDatetime()


@fieldwise_init
struct Stamp(Copyable, Defaultable, Movable):
    var at: TomlDatetime

    def __init__(out self):
        self.at = TomlDatetime()


@fieldwise_init
struct Text(Copyable, Defaultable, Movable):
    var s: String

    def __init__(out self):
        self.s = String()


@fieldwise_init
struct Count(Copyable, Defaultable, Movable):
    var n: Int

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct Wide(Copyable, Defaultable, Movable):
    var n: UInt64

    def __init__(out self):
        self.n = 0


@fieldwise_init
struct Spaced(Copyable, Defaultable, Movable):
    @__annotation(Rename("user name"))
    var user: String

    def __init__(out self):
        self.user = String()


def _kind_and_path[
    T: Deinitable
](s: String) raises -> Tuple[DerErrorKind, String]:
    try:
        _ = from_toml[T](s)
    except e:
        return (e.kind, e.path)
    raise Error("expected a DeserializationError")


def test_scalars_with_comments_and_any_order() raises:
    var p = from_toml[Package](
        "# a package\n"
        "version = 3   # trailing comment\n"
        "\n"
        '  name = "emberserde"\r\n'
        "stable = true\n"
        "score = 0.5\n"
        "published = 1979-05-27T07:32:00Z"
    )
    assert_equal(p.name, "emberserde")
    assert_equal(p.version, 3)
    assert_true(p.stable)
    assert_equal(p.score, 0.5)
    assert_equal(p.published.year, 1979)
    assert_equal(p.published.month, 5)
    assert_equal(p.published.day, 27)
    assert_equal(p.published.hour, 7)
    assert_equal(p.published.minute, 32)
    assert_equal(p.published.second, 0)
    assert_equal(p.published.offset_minutes.value(), 0)


def test_datetime_kinds() raises:
    var k = from_toml[Kinds](
        "offset = 1979-05-27T00:32:00.999999-07:00\n"
        "local = 1979-05-27T07:32:00\n"
        "date = 1979-05-27 # a local date\n"
        "time = 07:32:00.5\n"
    )
    assert_true(k.offset.has_date and k.offset.has_time)
    assert_equal(k.offset.nanosecond, 999999000)
    assert_equal(k.offset.offset_minutes.value(), -420)
    assert_true(k.local.has_date and k.local.has_time)
    assert_false(Bool(k.local.offset_minutes))
    assert_true(k.date.has_date)
    assert_false(k.date.has_time)
    assert_equal(k.date.day, 27)
    assert_false(k.time.has_date)
    assert_equal(k.time.hour, 7)
    assert_equal(k.time.nanosecond, 500000000)
    assert_false(Bool(k.time.offset_minutes))


def test_datetime_alternate_spellings() raises:
    assert_equal(
        String(from_toml[Stamp]("at = 1979-05-27t07:32:00z\n").at),
        "1979-05-27T07:32:00Z",
    )
    assert_equal(
        String(from_toml[Stamp]("at = 1979-05-27 07:32:00+05:30\n").at),
        "1979-05-27T07:32:00+05:30",
    )
    assert_equal(
        String(from_toml[Stamp]("at = 2000-02-29T07:32:00.1234567891Z\n").at),
        "2000-02-29T07:32:00.123456789Z",
    )


def test_datetime_from_a_json_string() raises:
    var p = from_json[Package](
        '{"name":"emberserde","version":3,"stable":true,"score":0.5,'
        '"published":"1979-05-27T07:32:00Z"}'
    )
    assert_equal(p.published.year, 1979)
    assert_equal(p.published.hour, 7)
    assert_equal(p.published.offset_minutes.value(), 0)


def test_quoted_datetime_is_a_type_mismatch() raises:
    var r = _kind_and_path[Stamp]('at = "1979-05-27T07:32:00Z"\n')
    assert_equal(r[0], DerErrorKind.TypeMismatch)
    assert_equal(r[1], ".at")


def test_datetime_into_string_is_a_type_mismatch() raises:
    var r = _kind_and_path[Text]("s = 1979-05-27\n")
    assert_equal(r[0], DerErrorKind.TypeMismatch)
    assert_equal(r[1], ".s")


def test_quoted_number_is_a_type_mismatch() raises:
    assert_equal(
        _kind_and_path[Count]('n = "3"\n')[0], DerErrorKind.TypeMismatch
    )


def test_wide_unsigned_with_underscores() raises:
    assert_equal(
        from_toml[Wide]("n = 18_446_744_073_709_551_615\n").n, UInt64.MAX
    )
    var bad = [
        "_18446744073709551615",
        "18446744073709551615_",
        "18__446744073709551615",
    ]
    for text in bad:
        var r = _kind_and_path[Wide](String("n = ") + text + "\n")
        assert_equal(r[0], DerErrorKind.InvalidValue, text)


def test_invalid_datetimes() raises:
    var bad = [
        "1979-13-01",
        "1979-02-30",
        "1900-02-29",
        "1979-05-27T24:00:00",
        "1979-05-27T07:60:00",
        "1979-05-27T07:32",
        "1979-05-27T07:32:00.",
        "1979-05-27T07:32:00+24:00",
        "1979-05-27X07:32:00",
        "07:32:00Z",
    ]
    for text in bad:
        var r = _kind_and_path[Stamp](String("at = ") + text + "\n")
        assert_equal(r[0], DerErrorKind.InvalidValue, text)


def test_string_escapes() raises:
    assert_equal(
        from_toml[Text]('s = "a\\"b\\\\c\\nd\\te\\u00E9\\U0001F525"\n').s,
        'a"b\\c\nd\teé🔥',
    )


def test_invalid_strings() raises:
    var bad = [
        's = "abc\n',
        's = "a\\xb"\n',
        's = "\\uD800"\n',
        's = "a\x01b"\n',
    ]
    for text in bad:
        assert_equal(_kind_and_path[Text](text)[0], DerErrorKind.InvalidValue)


def test_quoted_key() raises:
    assert_equal(from_toml[Spaced]('"user name" = "ada"\n').user, "ada")


def test_unsupported_syntax() raises:
    var bad = [
        "[table]\nn = 1\n",
        "n = [1, 2]\n",
        "n = { a = 1 }\n",
        "s = 'literal'\n",
        's = """multi"""\n',
        "a.b = 1\n",
    ]
    for text in bad:
        with assert_raises(contains="unsupported in this TOML subset"):
            _ = from_toml[Text](text)


def test_duplicate_key() raises:
    var r = _kind_and_path[Count]("n = 1\nn = 2\n")
    assert_equal(r[0], DerErrorKind.DuplicateField)


def test_unknown_keys_skipped() raises:
    var c = from_toml[Count](
        'name = "x"\nwhen = 1979-05-27 07:32:00\nn = 4\nok = true\n'
    )
    assert_equal(c.n, 4)


def test_two_values_on_one_line() raises:
    assert_equal(
        _kind_and_path[Package]("version = 3 stable = true\n")[0],
        DerErrorKind.InvalidValue,
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
