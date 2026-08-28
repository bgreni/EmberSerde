from std.testing import assert_equal, TestSuite
from _debug_format import debug_string
from emberserde.field import field


@fieldwise_init
struct Rec(Copyable, Movable):
    var a: Int

    @field(rename="b")
    var renamed: Int

    @field(skip=True)
    var hidden: Int


def test_field_rename_and_skip() raises:
    var r = Rec(
        a=1,
        renamed=2,
        hidden=3,
    )
    # `renamed` emits under "b"; `hidden` drops out and the field count is 2.
    assert_equal(debug_string(r), "test_field.Rec { a: 1, b: 2 }")


@fieldwise_init
struct AliasedRec(Copyable, Movable):
    @field(rename="primary", extra_names=List[String](["alias"]))
    var a: Int


def test_aliases_do_not_affect_output() raises:
    # Aliases are a deserialize-side concern only: the wire name is still the
    # single `rename`.
    assert_equal(
        debug_string(AliasedRec(a=1)),
        "test_field.AliasedRec { primary: 1 }",
    )


# A `skip_if` predicate must be a named top-level, non-capturing function —
# Mojo has no inline-lambda syntax, so a closure cannot be a decorator
# argument.
def _is_empty_string(s: String) -> Bool:
    return s.byte_length() == 0


@fieldwise_init
struct RecSkipIf(Copyable, Movable):
    var a: Int

    @field(skip_if=_is_empty_string)
    var name: String


def test_skip_if_true_omits_field() raises:
    # An empty `name` satisfies `_is_empty_string`, so it never reaches the
    # wire at all — not even as `name: ""`.
    assert_equal(
        debug_string(RecSkipIf(a=1, name=String())),
        "test_field.RecSkipIf { a: 1 }",
    )


def test_skip_if_false_keeps_field() raises:
    # A non-empty `name` fails the predicate, so it serializes normally.
    assert_equal(
        debug_string(RecSkipIf(a=1, name=String("x"))),
        'test_field.RecSkipIf { a: 1, name: "x" }',
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
