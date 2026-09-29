from std.builtin.rebind import downcast

from .field import TypedAnnotation
from .utils import Base


# A check run on a field right after it is read, attached like any other
# field attribute: `@__annotation(Range(0, 10), NonEmpty())`. On `False` the
# framework raises `InvalidValue` with `message()`. Conform to it to write
# your own check. Checks that carry a value of the field's type are also
# `TypedAnnotation`s (so a mismatch fails the build) and assert
# `T == Self.Type` inside `check`, which also catches a mistyped arm nested
# in a combinator, where the build-time lookup cannot see it.
trait FieldCheck(Base):
    def check[T: AnyType](self, value: T) -> Bool:
        ...

    def message(self) -> StaticString:
        ...


# Length as `Size`/`NonEmpty` see it: a `String` counts bytes, anything else
# must be `Sized`.
@always_inline
def _length[T: AnyType](value: T) -> Int:
    comptime if T == String:
        return rebind[String](value).byte_length()
    else:
        comptime assert conforms_to(
            T, Sized
        ), "Size/NonEmpty need a String or Sized field"
        return rebind[downcast[T, Sized]](value).__len__()


# Passes when `f(value)` is `True`.
struct Validate[T: AnyType](FieldCheck, TypedAnnotation):
    comptime Type = Self.T
    var f: def(Self.T) thin -> Bool
    var msg: StaticString

    def __init__(
        out self,
        f: def(Self.T) thin -> Bool,
        msg: StaticString = "Validation failed",
    ):
        self.f = f
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime assert (
            U == Self.T
        ), "Validate's argument type must match the field's type"
        return self.f(rebind[Self.T](value))

    def message(self) -> StaticString:
        return self.msg


# Passes when `min <= value <= max`.
struct Range[T: Comparable & Copyable & Deinitable](
    FieldCheck, TypedAnnotation
):
    comptime Type = Self.T
    var min: Self.T
    var max: Self.T
    var msg: StaticString

    def __init__(
        out self,
        min: Self.T,
        max: Self.T,
        msg: StaticString = "Value out of range",
    ):
        self.min = min.copy()
        self.max = max.copy()
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime assert (
            U == Self.T
        ), "Range's bounds must match the field's type"
        ref v = rebind[Self.T](value)
        return self.min <= v and v <= self.max

    def message(self) -> StaticString:
        return self.msg


# Passes when the value equals `value`.
struct Eq[T: Equatable & Copyable & Deinitable](FieldCheck, TypedAnnotation):
    comptime Type = Self.T
    var value: Self.T
    var msg: StaticString

    def __init__(
        out self, value: Self.T, msg: StaticString = "Value is not equal"
    ):
        self.value = value.copy()
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime assert U == Self.T, "Eq's value must match the field's type"
        return rebind[Self.T](value) == self.value

    def message(self) -> StaticString:
        return self.msg


# Passes when the value equals one of `accepted`: `Enum["dev", "prod"]()`.
# The values are parameters, not stored fields, so a check costs nothing but
# the comparisons (a `List` field would heap-allocate on every check). A
# set-membership check, unrelated to `Variant` enums.
struct Enum[T: Equatable & Copyable & Deinitable, //, *accepted: T](
    FieldCheck, TypedAnnotation
):
    comptime Type = Self.T
    var msg: StaticString

    def __init__(out self, msg: StaticString = "Value not in options"):
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime assert U == Self.T, "Enum's values must match the field's type"
        comptime for k in range(len(Self.accepted)):
            if rebind[Self.T](value) == materialize[Self.accepted[k]]():
                return True
        return False

    def message(self) -> StaticString:
        return self.msg


# Passes when `min <= length <= max` (a `String` counts bytes).
struct Size(FieldCheck):
    var min: Int
    var max: Int
    var msg: StaticString

    def __init__(
        out self,
        min: Int,
        max: Int,
        msg: StaticString = "Value out of size range",
    ):
        self.min = min
        self.max = max
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        var n = _length(value)
        return self.min <= n and n <= self.max

    def message(self) -> StaticString:
        return self.msg


# Passes when the length is above zero (a `String` counts bytes).
struct NonEmpty(FieldCheck):
    var msg: StaticString

    def __init__(out self, msg: StaticString = "Value must not be empty"):
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        return _length(value) > 0

    def message(self) -> StaticString:
        return self.msg


# Passes when no two elements are equal.
struct Unique(FieldCheck):
    var msg: StaticString

    def __init__(out self, msg: StaticString = "Values are not unique"):
        self.msg = msg

    # ponytail: pairwise O(n²), fine for config-sized lists; hash elements
    # when a caller validates large ones.
    def check[U: AnyType](self, value: U) -> Bool:
        comptime assert conforms_to(
            U, Iterable
        ), "Unique needs an Iterable field"
        ref v = rebind[downcast[U, Iterable]](value)
        # Driven off the raw iterators rather than a `for` loop: a generic
        # `Iterator.Element` is only `Movable`, so a loop binding would be a
        # value the compiler cannot drop. Taking each element by hand lets us
        # consume it through a `downcast` that carries `Deinitable`.
        comptime Elem = downcast[
            downcast[U, Iterable].IteratorType[origin_of(v)].Element,
            Equatable & Movable & Deinitable,
        ]
        var i = 0
        var outer = v.__iter__()
        while True:
            try:
                var a = rebind_var[Elem](outer.__next__())
                var j = 0
                var inner = v.__iter__()
                while True:
                    try:
                        var b = rebind_var[Elem](inner.__next__())
                        var dup = i != j and a == b
                        _ = b^
                        if dup:
                            _ = a^
                            return False
                        j += 1
                    except StopIteration:
                        break
                _ = a^
                i += 1
            except StopIteration:
                break
        return True

    def message(self) -> StaticString:
        return self.msg


# Passes when `inner` fails: `Not(Eq(0))`.
struct Not[C: FieldCheck](FieldCheck):
    var inner: Self.C
    var msg: StaticString

    def __init__(
        out self,
        var inner: Self.C,
        msg: StaticString = "Expected validator to fail",
    ):
        self.inner = inner^
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        return not self.inner.check(value)

    def message(self) -> StaticString:
        return self.msg


# The combinators below store their arms in a `Tuple` built from the variadic
# pack the way stdlib `Tuple.__init__` does (mark the tuple initialized, then
# move each element in). A pack cannot be forwarded to a shared helper, so
# each constructor repeats those lines. If this ever breaks on a nightly, the
# fallback is a `@fieldwise_init` tuple field, spelled `AnyOf((Eq(1), Eq(2)))`.


# Passes when at least one arm passes: `AnyOf(Eq(1), Range(10, 20))`.
struct AnyOf[*Ts: FieldCheck](FieldCheck):
    var checks: Tuple[*Self.Ts]
    var msg: StaticString

    def __init__(
        out self,
        var *checks: *Self.Ts,
        msg: StaticString = "Value not in options",
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.checks)
        )

        @__parameter
        def put[idx: Int](var elt: Self.Ts[idx]):
            Pointer(to=self.checks[idx]).unsafe_write(elt^)

        checks^.consume_elements[put]()
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime for k in range(Self.Ts.length):
            if self.checks[k].check(value):
                return True
        return False

    def message(self) -> StaticString:
        return self.msg


# Passes when exactly one arm passes.
struct OneOf[*Ts: FieldCheck](FieldCheck):
    var checks: Tuple[*Self.Ts]
    var msg: StaticString

    def __init__(
        out self,
        var *checks: *Self.Ts,
        msg: StaticString = "Value must match exactly one option",
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.checks)
        )

        @__parameter
        def put[idx: Int](var elt: Self.Ts[idx]):
            Pointer(to=self.checks[idx]).unsafe_write(elt^)

        checks^.consume_elements[put]()
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        var n = 0
        comptime for k in range(Self.Ts.length):
            if self.checks[k].check(value):
                n += 1
        return n == 1

    def message(self) -> StaticString:
        return self.msg


# Passes when no arm passes.
struct NoneOf[*Ts: FieldCheck](FieldCheck):
    var checks: Tuple[*Self.Ts]
    var msg: StaticString

    def __init__(
        out self,
        var *checks: *Self.Ts,
        msg: StaticString = "Value matched a rejected validator",
    ):
        __mlir_op.`lit.ownership.mark_initialized`(
            __get_mvalue_as_litref(self.checks)
        )

        @__parameter
        def put[idx: Int](var elt: Self.Ts[idx]):
            Pointer(to=self.checks[idx]).unsafe_write(elt^)

        checks^.consume_elements[put]()
        self.msg = msg

    def check[U: AnyType](self, value: U) -> Bool:
        comptime for k in range(Self.Ts.length):
            if self.checks[k].check(value):
                return False
        return True

    def message(self) -> StaticString:
        return self.msg
