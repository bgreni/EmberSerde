from std.testing import assert_equal, TestSuite
from _json_format import from_json, to_json
from emberserde.error import DerErrorKind, SerErrorKind
from emberserde.field import (
    Default,
    Rename,
    SerializeWith,
    Transform,
    clamp,
)
from emberserde.validate import (
    AnyOf,
    Enum,
    Eq,
    FieldCheck,
    NonEmpty,
    NoneOf,
    Not,
    OneOf,
    Range,
    Size,
    Unique,
    Validate,
)


# What a failing read raised. Kind `Custom` and empty strings mean it did not
# raise. A sentinel rather than `assert_raises`, so a test can pin the kind,
# message and path together.
@fieldwise_init
struct Failure(Copyable, Movable):
    var kind: DerErrorKind
    var message: String
    var path: String


def fail_of[T: Deinitable](var s: String) raises -> Failure:
    var f = Failure(DerErrorKind.Custom, String(), String())
    try:
        _ = from_json[T](s^)
    except e:
        f = Failure(e.kind, e.message, e.path)
    return f^


def assert_fails[
    T: Deinitable
](var s: String, message: String, path: String) raises:
    var f = fail_of[T](s^)
    assert_equal(f.kind, DerErrorKind.InvalidValue)
    assert_equal(f.message, message)
    assert_equal(f.path, path)


@fieldwise_init
struct Ranged(Movable):
    @__annotation(Range(0, 10))
    var i: Int

    @__annotation(Range(0.0, 1.0))
    var f: Float64


def test_range() raises:
    var r = from_json[Ranged]('{"i": 0, "f": 1.0}')
    assert_equal(r.i, 0)
    assert_equal(r.f, 1.0)
    r = from_json[Ranged]('{"i": 10, "f": 0.0}')
    assert_equal(r.i, 10)
    assert_fails[Ranged]('{"i": -1, "f": 0.5}', "Value out of range", ".i")
    assert_fails[Ranged]('{"i": 11, "f": 0.5}', "Value out of range", ".i")
    assert_fails[Ranged]('{"i": 5, "f": 1.1}', "Value out of range", ".f")
    assert_fails[Ranged]('{"i": 5, "f": -0.1}', "Value out of range", ".f")


@fieldwise_init
struct Port(Movable):
    @__annotation(Range(1, 65535, msg="bad port"))
    var port: Int


def test_custom_message() raises:
    assert_equal(from_json[Port]('{"port": 8080}').port, 8080)
    assert_fails[Port]('{"port": 0}', "bad port", ".port")


@fieldwise_init
struct Outer(Movable):
    var inner: Port


def test_nested_path() raises:
    assert_fails[Outer]('{"inner": {"port": 0}}', "bad port", ".inner.port")


@fieldwise_init
struct Choice(Defaultable, Movable):
    @__annotation(Eq("on"))
    var flag: String

    @__annotation(Enum["dev", "prod"]())
    var env: String

    @__annotation(Enum[1, 2, 3](msg="bad level"))
    var level: Int

    def __init__(out self):
        self.flag = String()
        self.env = String()
        self.level = 0


def test_eq_and_enum() raises:
    var c = from_json[Choice]('{"flag": "on", "env": "prod", "level": 2}')
    assert_equal(c.flag, "on")
    assert_equal(c.env, "prod")
    assert_equal(c.level, 2)
    assert_fails[Choice](
        '{"flag": "off", "env": "prod", "level": 2}',
        "Value is not equal",
        ".flag",
    )
    assert_fails[Choice](
        '{"flag": "on", "env": "qa", "level": 2}',
        "Value not in options",
        ".env",
    )
    assert_fails[Choice](
        '{"flag": "on", "env": "dev", "level": 5}', "bad level", ".level"
    )


@fieldwise_init
struct Sizes(Defaultable, Movable):
    @__annotation(Size(3, 5))
    var s: String

    @__annotation(Size(1, 3))
    var xs: List[Int]

    @__annotation(NonEmpty())
    var name: String

    @__annotation(NonEmpty())
    var tags: List[String]

    def __init__(out self):
        self.s = String()
        self.xs = []
        self.name = String()
        self.tags = []


def _sizes(s: String, xs: String, name: String, tags: String) -> String:
    return (
        '{"s": '
        + s
        + ', "xs": '
        + xs
        + ', "name": '
        + name
        + ', "tags": '
        + tags
        + "}"
    )


def test_size_and_non_empty() raises:
    var v = from_json[Sizes](_sizes('"abc"', "[1]", '"a"', '["t"]'))
    assert_equal(v.s, "abc")
    v = from_json[Sizes](_sizes('"abcde"', "[1, 2, 3]", '"a"', '["t"]'))
    assert_equal(len(v.xs), 3)
    assert_fails[Sizes](
        _sizes('"ab"', "[1]", '"a"', '["t"]'), "Value out of size range", ".s"
    )
    assert_fails[Sizes](
        _sizes('"abcdef"', "[1]", '"a"', '["t"]'),
        "Value out of size range",
        ".s",
    )
    assert_fails[Sizes](
        _sizes('"abc"', "[]", '"a"', '["t"]'), "Value out of size range", ".xs"
    )
    assert_fails[Sizes](
        _sizes('"abc"', "[1, 2, 3, 4]", '"a"', '["t"]'),
        "Value out of size range",
        ".xs",
    )
    assert_fails[Sizes](
        _sizes('"abc"', "[1]", '""', '["t"]'),
        "Value must not be empty",
        ".name",
    )
    assert_fails[Sizes](
        _sizes('"abc"', "[1]", '"a"', "[]"), "Value must not be empty", ".tags"
    )


def test_size_counts_bytes() raises:
    # Two characters, four bytes: inside Size(3, 5) only because `String`
    # length is its byte length.
    var v = from_json[Sizes](_sizes('"éé"', "[1]", '"a"', '["t"]'))
    assert_equal(v.s, "éé")


@fieldwise_init
struct Uniq(Defaultable, Movable):
    @__annotation(Unique())
    var ints: List[Int]

    @__annotation(Unique())
    var strs: List[String]

    def __init__(out self):
        self.ints = []
        self.strs = []


def test_unique() raises:
    var u = from_json[Uniq]('{"ints": [1, 2, 3], "strs": ["a", "b"]}')
    assert_equal(len(u.ints), 3)
    u = from_json[Uniq]('{"ints": [], "strs": []}')
    assert_equal(len(u.ints), 0)
    assert_fails[Uniq](
        '{"ints": [1, 2, 1], "strs": []}', "Values are not unique", ".ints"
    )
    assert_fails[Uniq](
        '{"ints": [], "strs": ["a", "b", "a"]}',
        "Values are not unique",
        ".strs",
    )


@fieldwise_init
struct Checked(Movable):
    @__annotation(Validate(lambda (x: Int) -> Bool: x % 2 == 0, "must be even"))
    var even: Int

    @__annotation(Validate(lambda (x: Int) -> Bool: x > 0))
    var pos: Int


def test_validate_message() raises:
    assert_equal(from_json[Checked]('{"even": 4, "pos": 1}').even, 4)
    assert_fails[Checked]('{"even": 3, "pos": 1}', "must be even", ".even")
    assert_fails[Checked]('{"even": 4, "pos": 0}', "Validation failed", ".pos")


@fieldwise_init
struct Ordered(Movable):
    @__annotation(Range(0, 10), Eq(4))
    var n: Int


def test_checks_run_in_order() raises:
    assert_equal(from_json[Ordered]('{"n": 4}').n, 4)
    assert_fails[Ordered]('{"n": 20}', "Value out of range", ".n")
    assert_fails[Ordered]('{"n": 5}', "Value is not equal", ".n")


@fieldwise_init
struct Stacked(Movable):
    @__annotation(Rename("n"), Default(99), Range(0, 10))
    var num: Int


def test_default_is_not_checked() raises:
    assert_equal(from_json[Stacked]('{"n": 5}').num, 5)
    # 99 is out of range, but a default fill is never checked.
    assert_equal(from_json[Stacked]("{}").num, 99)
    # The path names the declared field, not the wire key.
    assert_fails[Stacked]('{"n": 11}', "Value out of range", ".num")


@fieldwise_init
struct IsEven(FieldCheck):
    def check[T: AnyType](self, value: T) -> Bool:
        comptime assert T == Int, "IsEven needs an Int field"
        return rebind[Int](value) % 2 == 0

    def message(self) -> StaticString:
        return "custom check: odd"


@fieldwise_init
struct Custom(Movable):
    @__annotation(IsEven())
    var n: Int


def test_user_written_check() raises:
    assert_equal(from_json[Custom]('{"n": 2}').n, 2)
    assert_fails[Custom]('{"n": 3}', "custom check: odd", ".n")


def test_checks_do_not_touch_serialization() raises:
    assert_equal(to_json(Port(0)), '{"port":0}')
    assert_equal(to_json(Stacked(99)), '{"n":99}')


@fieldwise_init
struct Combined(Movable):
    @__annotation(AnyOf(Eq(1), Range(10, 20)))
    var any: Int

    @__annotation(OneOf(Range(0, 10), Range(5, 15)))
    var one: Int

    @__annotation(NoneOf(Eq(3), Range(100, 200)))
    var none: Int

    @__annotation(Not(Eq(0)))
    var nonzero: Int


def _combined(any: Int, one: Int, none: Int, nonzero: Int) -> String:
    return String(
        t'{{"any": {any}, "one": {one}, "none": {none}, "nonzero": {nonzero}}}'
    )


def test_combinators() raises:
    var c = from_json[Combined](_combined(1, 2, 5, 7))
    assert_equal(c.any, 1)
    c = from_json[Combined](_combined(15, 12, 50, -1))
    assert_equal(c.any, 15)
    assert_fails[Combined](
        _combined(5, 2, 5, 7), "Value not in options", ".any"
    )
    # OneOf: both arms match 7, neither matches 20.
    assert_fails[Combined](
        _combined(1, 7, 5, 7), "Value must match exactly one option", ".one"
    )
    assert_fails[Combined](
        _combined(1, 20, 5, 7), "Value must match exactly one option", ".one"
    )
    assert_fails[Combined](
        _combined(1, 2, 3, 7), "Value matched a rejected validator", ".none"
    )
    assert_fails[Combined](
        _combined(1, 2, 150, 7), "Value matched a rejected validator", ".none"
    )
    assert_fails[Combined](
        _combined(1, 2, 5, 0), "Expected validator to fail", ".nonzero"
    )


@fieldwise_init
struct Colors(Defaultable, Movable):
    @__annotation(OneOf(Eq("red"), Eq("green"), Eq("blue")))
    var color: String

    @__annotation(AnyOf(Eq(1), Eq(2), msg="one or two"))
    var small: Int

    @__annotation(Not(AnyOf(Eq(1), Eq(2)), msg="not one or two"))
    var big: Int

    def __init__(out self):
        self.color = String()
        self.small = 0
        self.big = 0


def test_combinator_messages_and_nesting() raises:
    var c = from_json[Colors]('{"color": "red", "small": 2, "big": 3}')
    assert_equal(c.color, "red")
    assert_fails[Colors](
        '{"color": "yellow", "small": 2, "big": 3}',
        "Value must match exactly one option",
        ".color",
    )
    assert_fails[Colors](
        '{"color": "red", "small": 3, "big": 3}', "one or two", ".small"
    )
    assert_fails[Colors](
        '{"color": "red", "small": 2, "big": 1}', "not one or two", ".big"
    )


def to_len(s: String) -> Int:
    return s.byte_length()


def parse_level(s: String) raises -> Int:
    if s == "low":
        return 1
    if s == "high":
        return 2
    raise Error("unknown level: " + s)


@fieldwise_init
struct Transformed(Movable):
    @__annotation(Transform(to_len))
    var n: Int

    # The check runs on the converted value.
    @__annotation(Transform(parse_level), Eq(1, msg="only low allowed"))
    var level: Int


def test_transform() raises:
    var t = from_json[Transformed]('{"n": "abcd", "level": "low"}')
    assert_equal(t.n, 4)
    assert_equal(t.level, 1)
    assert_fails[Transformed](
        '{"n": "a", "level": "mid"}', "unknown level: mid", ".level"
    )
    assert_fails[Transformed](
        '{"n": "a", "level": "high"}', "only low allowed", ".level"
    )
    # The wire value must be the transform's input type.
    var f = fail_of[Transformed]('{"n": 5, "level": "low"}')
    assert_equal(f.kind, DerErrorKind.TypeMismatch)
    assert_equal(f.path, ".n")
    # One-way: written back as the field's own type.
    assert_equal(to_json(Transformed(4, 1)), '{"n":4,"level":1}')


@fieldwise_init
struct TransformDefault(Movable):
    @__annotation(Transform(parse_level), Default(7))
    var level: Int


def test_transform_with_default() raises:
    # Missing key: the default fills and `parse_level` never runs.
    assert_equal(from_json[TransformDefault]("{}").level, 7)
    assert_equal(from_json[TransformDefault]('{"level": "high"}').level, 2)


# A check on the struct itself sees the whole value, so it can relate fields.
@__annotation(
    Validate(
        lambda (d: DateRange) -> Bool: d.start <= d.end, "start must be <= end"
    )
)
@fieldwise_init
struct DateRange(Movable):
    var start: Int
    var end: Int


@fieldwise_init
struct Trip(Movable):
    var when: DateRange


def _ordered(r: OpenRange) -> Bool:
    return r.start <= r.end


@__annotation(Validate(_ordered, "start must be <= end"))
@fieldwise_init
struct OpenRange(Movable):
    @__annotation(Default(10))
    var start: Int
    var end: Int


# Every struct-level check must pass, in order, like field checks.
@__annotation(
    Validate(lambda (p: Pair) -> Bool: p.a != 0, "a must be set"),
    Validate(lambda (p: Pair) -> Bool: p.a < p.b, "a must be < b"),
)
@fieldwise_init
struct Pair(Movable):
    var a: Int
    var b: Int


def test_validate_struct() raises:
    var d = from_json[DateRange]('{"start": 1, "end": 5}')
    assert_equal(d.end, 5)
    assert_fails[DateRange](
        '{"start": 6, "end": 5}', "start must be <= end", ""
    )
    # Nested: the parent prepends the field that held the struct.
    assert_fails[Trip](
        '{"when": {"start": 6, "end": 5}}', "start must be <= end", ".when"
    )
    # Runs after missing fields are filled, so it sees the default.
    assert_equal(from_json[OpenRange]('{"end": 20}').start, 10)
    assert_fails[OpenRange]('{"end": 5}', "start must be <= end", "")
    assert_fails[Pair]('{"a": 0, "b": 5}', "a must be set", "")
    assert_fails[Pair]('{"a": 6, "b": 5}', "a must be < b", "")
    assert_equal(from_json[Pair]('{"a": 1, "b": 5}').b, 5)
    # Serialization does not validate.
    assert_equal(to_json(DateRange(6, 5)), '{"start":6,"end":5}')


def redact(s: String) -> String:
    return "********"


@fieldwise_init
struct Creds(Defaultable, Movable):
    var user: String

    @__annotation(SerializeWith(redact))
    var password: String

    def __init__(out self):
        self.user = String()
        self.password = String()


def test_serialize_with() raises:
    # Read as itself, written through `redact`.
    var c = from_json[Creds]('{"user": "bg", "password": "hunter2"}')
    assert_equal(c.password, "hunter2")
    assert_equal(to_json(c), '{"user":"bg","password":"********"}')


def non_negative(n: Int) raises -> Int:
    if n < 0:
        raise Error("negative on write")
    return n


@fieldwise_init
struct Written(Movable):
    @__annotation(SerializeWith(non_negative))
    var n: Int


def test_serialize_with_raising() raises:
    assert_equal(to_json(Written(3)), '{"n":3}')
    var kind = SerErrorKind.Custom
    var message = String()
    try:
        _ = to_json(Written(-1))
    except e:
        kind = e.kind
        message = e.message
    assert_equal(kind, SerErrorKind.InvalidValue)
    assert_equal(message, "negative on write")


@fieldwise_init
struct Clamped(Movable):
    @__annotation(Transform(clamp[0, 100]))
    var volume: Int

    @__annotation(Transform(clamp[0.0, 1.0]))
    var ratio: Float64


def test_clamp() raises:
    var c = from_json[Clamped]('{"volume": 150, "ratio": -0.5}')
    assert_equal(c.volume, 100)
    assert_equal(c.ratio, 0.0)
    c = from_json[Clamped]('{"volume": -5, "ratio": 1.5}')
    assert_equal(c.volume, 0)
    assert_equal(c.ratio, 1.0)
    c = from_json[Clamped]('{"volume": 42, "ratio": 0.25}')
    assert_equal(c.volume, 42)
    assert_equal(c.ratio, 0.25)
    # Written back as the stored (clamped) value.
    assert_equal(to_json(Clamped(100, 1.0)), '{"volume":100,"ratio":1.0}')


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
