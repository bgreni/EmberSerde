from std.testing import assert_equal, assert_false, assert_true, TestSuite
from _debug_format import debug_string
from emberserde.field import Rename
from emberserde.struct_modifiers import (
    RenameAll,
    RenamePolicy,
    apply_rename_policy,
)


@fieldwise_init
struct SnakeRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.SnakeCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct CamelRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct PascalRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.PascalCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct KebabRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.KebabCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct ScreamingSnakeRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.ScreamingSnakeCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct ScreamingKebabRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.ScreamingKebabCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct LowerRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.LowerCase
    var first_name: Int
    var age: Int


@fieldwise_init
struct UpperRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.UpperCase
    var first_name: Int
    var age: Int


def test_rename_all_snake_is_identity() raises:
    assert_equal(
        debug_string(SnakeRec(1, 2)),
        "test_struct_modifiers.SnakeRec { first_name: 1, age: 2 }",
    )


def test_rename_all_camel() raises:
    assert_equal(
        debug_string(CamelRec(1, 2)),
        "test_struct_modifiers.CamelRec { firstName: 1, age: 2 }",
    )


def test_rename_all_pascal() raises:
    assert_equal(
        debug_string(PascalRec(1, 2)),
        "test_struct_modifiers.PascalRec { FirstName: 1, Age: 2 }",
    )


def test_rename_all_kebab() raises:
    assert_equal(
        debug_string(KebabRec(1, 2)),
        "test_struct_modifiers.KebabRec { first-name: 1, age: 2 }",
    )


def test_rename_all_screaming_snake() raises:
    assert_equal(
        debug_string(ScreamingSnakeRec(1, 2)),
        "test_struct_modifiers.ScreamingSnakeRec { FIRST_NAME: 1, AGE: 2 }",
    )


def test_rename_all_screaming_kebab() raises:
    assert_equal(
        debug_string(ScreamingKebabRec(1, 2)),
        "test_struct_modifiers.ScreamingKebabRec { FIRST-NAME: 1, AGE: 2 }",
    )


def test_rename_all_lower() raises:
    assert_equal(
        debug_string(LowerRec(1, 2)),
        "test_struct_modifiers.LowerRec { firstname: 1, age: 2 }",
    )


def test_rename_all_upper() raises:
    assert_equal(
        debug_string(UpperRec(1, 2)),
        "test_struct_modifiers.UpperRec { FIRSTNAME: 1, AGE: 2 }",
    )


@fieldwise_init
struct OverrideRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.CamelCase
    var first_name: Int
    var keep_me: Rename[Int, String("kept")]


def test_field_rename_overrides_policy() raises:
    # `first_name` follows the camelCase policy; `keep_me`'s field-level rename
    # wins over it (the policy alone would yield "keepMe").
    var r = OverrideRec(1, Rename[Int, String("kept")](value=2))
    assert_equal(
        debug_string(r),
        "test_struct_modifiers.OverrideRec { firstName: 1, kept: 2 }",
    )


# Fields declared in non-snake_case: the policy must tokenize the declared name
# rather than assume snake_case input.
@fieldwise_init
struct CamelDeclRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.SnakeCase
    var firstName: Int
    var parseHTTPResponse: Int


def test_rename_all_tokenizes_non_snake_input() raises:
    assert_equal(
        debug_string(CamelDeclRec(1, 2)),
        (
            "test_struct_modifiers.CamelDeclRec"
            " { first_name: 1, parse_http_response: 2 }"
        ),
    )


@fieldwise_init
struct PascalDeclRec(Copyable, Movable, RenameAll):
    comptime FieldRenamePolicy = RenamePolicy.KebabCase
    var FirstName: Int
    var age: Int


def test_rename_all_pascal_input_to_kebab() raises:
    assert_equal(
        debug_string(PascalDeclRec(1, 2)),
        "test_struct_modifiers.PascalDeclRec { first-name: 1, age: 2 }",
    )


# ---------------------------------------------------------------------------
# Direct unit tests for `apply_rename_policy` / `RenamePolicy`, independent of
# the serialization path.
# ---------------------------------------------------------------------------


def test_policy_two_words_every_policy() raises:
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("first_name"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.CamelCase]("first_name"), "firstName"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("first_name"), "FirstName"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.KebabCase]("first_name"), "first-name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.ScreamingSnakeCase]("first_name"),
        "FIRST_NAME",
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.ScreamingKebabCase]("first_name"),
        "FIRST-NAME",
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.LowerCase]("first_name"), "firstname"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.UpperCase]("first_name"), "FIRSTNAME"
    )


def test_policy_input_convention_independent() raises:
    # Every input convention normalizes to the same words, so the output under
    # a given policy is identical regardless of how the field was declared.
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("first_name"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("firstName"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("FirstName"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("first-name"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("FIRST_NAME"), "first_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("firstName"), "FirstName"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("first-name"), "FirstName"
    )


def test_policy_single_word() raises:
    assert_equal(apply_rename_policy[RenamePolicy.SnakeCase]("name"), "name")
    assert_equal(apply_rename_policy[RenamePolicy.CamelCase]("name"), "name")
    assert_equal(apply_rename_policy[RenamePolicy.PascalCase]("name"), "Name")
    assert_equal(apply_rename_policy[RenamePolicy.UpperCase]("name"), "NAME")
    assert_equal(
        apply_rename_policy[RenamePolicy.ScreamingSnakeCase]("name"), "NAME"
    )
    assert_equal(apply_rename_policy[RenamePolicy.PascalCase]("x"), "X")


def test_policy_acronyms() raises:
    # An acronym run splits before its final capital when a lowercase follows;
    # the run is then lowercased, so camel/Pascal render it as a normal word.
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("parseHTTPResponse"),
        "parse_http_response",
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.CamelCase]("parseHTTPResponse"),
        "parseHttpResponse",
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("parseHTTPResponse"),
        "ParseHttpResponse",
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("HTTPServer"), "http_server"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("HTTPServer"), "HttpServer"
    )


def test_policy_digits() raises:
    # Digits stay attached to a word, except a digit->uppercase transition,
    # which starts a new word.
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("field2"), "field2"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.PascalCase]("field2"), "Field2"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("user2name"), "user2name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.SnakeCase]("user2Name"), "user2_name"
    )
    assert_equal(
        apply_rename_policy[RenamePolicy.CamelCase]("user2Name"), "user2Name"
    )


def test_policy_separator_edges() raises:
    # Leading, trailing, and doubled separators never produce empty words.
    assert_equal(apply_rename_policy[RenamePolicy.SnakeCase]("__a__b__"), "a_b")
    assert_equal(apply_rename_policy[RenamePolicy.PascalCase]("a_b"), "AB")
    assert_equal(apply_rename_policy[RenamePolicy.KebabCase]("a-b-c"), "a-b-c")


def test_rename_policy_write_to() raises:
    assert_equal(String(RenamePolicy.SnakeCase), "SnakeCase")
    assert_equal(String(RenamePolicy.CamelCase), "CamelCase")
    assert_equal(String(RenamePolicy.PascalCase), "PascalCase")
    assert_equal(String(RenamePolicy.KebabCase), "KebabCase")
    assert_equal(String(RenamePolicy.ScreamingSnakeCase), "ScreamingSnakeCase")
    assert_equal(String(RenamePolicy.ScreamingKebabCase), "ScreamingKebabCase")
    assert_equal(String(RenamePolicy.LowerCase), "LowerCase")
    assert_equal(String(RenamePolicy.UpperCase), "UpperCase")
    assert_equal(String(RenamePolicy(99)), "RenamePolicy(99)")


def test_rename_policy_equality() raises:
    assert_true(RenamePolicy.SnakeCase == RenamePolicy.SnakeCase)
    assert_false(RenamePolicy.SnakeCase == RenamePolicy.CamelCase)
    assert_true(RenamePolicy.SnakeCase != RenamePolicy.CamelCase)
    assert_false(RenamePolicy.CamelCase != RenamePolicy.CamelCase)


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
