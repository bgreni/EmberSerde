from std.reflection import Decorator

from .utils import Base


# Per-field serialization attributes, serde's `#[serde(...)]` on a field.
# Applied to the declaration itself, so the field keeps its own type — there is
# no wrapper to unwrap at the use site:
#
#     struct Person:
#         @field(rename="n", extra_names=List[String](["nom"]))
#         var name: String
#
# `FieldT` is a *site-derived* parameter: the compiler binds it to the type of
# whatever `var` this decorator is attached to, regardless of which arguments
# a given call passed. `@field(rename="n")` and `@field(skip_if=is_empty)` on
# the very same `var name: String` are both `field[String]` — that type
# stability is what lets `field_dec[T, i]` (`field_meta.mojo`) query with one
# spelling and see every `@field(...)` on a field, whichever of its optional
# payloads that particular call set.
#
# The bound is `Base` (`Movable & Deinitable`), not `AnyType` and not
# `ImplicitlyCopyable`. Storing `default` as a *value* forces something
# stronger than `AnyType`, but `ImplicitlyCopyable` would be too strong:
# `List` and `Dict` are `Copyable` but not `ImplicitlyCopyable`, so that bound
# would make `@field(...)` unattachable to any collection field, even just to
# set `rename`. `Movable & Deinitable` is reached by taking `default` as an
# owned argument and transferring it (`self.default = default^`) rather than
# assigning it — an `ImplicitlyCopyable` plain assignment is not required.
struct field[FieldT: Base](Decorator):
    var rename: Optional[String]
    var extra_names: Optional[List[String]]
    var skip: Bool
    # Fill an absent field by default-constructing it (serde's bare
    # `#[serde(default)]`) rather than raising `MissingField`.
    var fill_if_missing: Bool
    # An explicit default *value* applied when the field is absent from the
    # wire, rather than default-constructing it (serde's
    # `#[serde(default = "path")]`). Wins over the bare `fill_if_missing`
    # default-construct behavior when both would apply — see
    # `field_meta.mojo`'s `has_default`, which documents the full
    # precedence.
    var default: Optional[Self.FieldT]
    # A predicate: when it returns `True` on the field's current value, the
    # field is omitted from serialization entirely, rather than merely
    # emitted with some "default-ish" value. Must name a top-level,
    # non-capturing function — Mojo has no inline-lambda syntax, so a closure
    # cannot be a decorator argument (see `field_meta.mojo`'s `is_skipped`
    # for how comptime-vs-runtime invocation is split).
    var skip_if: Optional[def (Self.FieldT) thin -> Bool]

    # Keyword-only: the attributes are independent, and a positional
    # `@field("n")` would read as a wire name without saying so.
    def __init__(
        out self,
        *,
        var rename: Optional[String] = None,
        var extra_names: Optional[List[String]] = None,
        skip: Bool = False,
        skip_if: Optional[def (Self.FieldT) thin -> Bool] = None,
        fill_if_missing: Bool = False,
        var default: Optional[Self.FieldT] = None,
    ):
        self.rename = rename^
        self.extra_names = extra_names^
        self.skip = skip
        self.skip_if = skip_if
        # A skipped field is never on the wire, so it always fills; an
        # explicit `default` implies the same (serde's `default = "path"`
        # implies the bare `default` behavior too).
        self.fill_if_missing = skip or fill_if_missing or Bool(default)
        self.default = default^
