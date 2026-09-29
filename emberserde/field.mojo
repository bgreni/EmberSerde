from .utils import Base


# Field attributes, attached as `@__annotation(Rename("b"), Default(3))` and
# read back by the reflection defaults through `reflect[T].field_annotations`.
# Annotations are inert: the field keeps its own type, layout and
# conformances.


# `Default`, `Transform` and the valued checks (`Validate`, `Range`, `Eq`,
# `Enum`) carry a value of the field's own type. Publishing it as `Type` lets
# the lookup fail the build on a mismatch (`Default(1)` on an
# `Int64` field infers `Default[Int]`), which would otherwise match nothing and
# be silently ignored.
trait TypedAnnotation(Base):
    comptime Type: AnyType


# The field's wire name. On a struct, its tag as a `Variant` arm.
@fieldwise_init
struct Rename(Base):
    var name: StaticString


# An extra wire name the field is also read from. Repeat for more than one.
@fieldwise_init
struct Alias(Base):
    var name: StaticString


# Never written; filled from `Default`, else `T()`, on read.
@fieldwise_init
struct Skip(Base):
    pass


# The value a field absent from the wire takes. Needs no `T()`, so it works
# for non-Defaultable field types.
@fieldwise_init
struct Default[T: Base](TypedAnnotation):
    comptime Type = Self.T
    var value: Self.T


# Changes what is read for a field: the framework reads `In` off the wire and
# stores `apply(value)`. `Transform` is the stock one; the framework finds it
# through this trait because `In` is not known to the lookup. `Out` restates
# `Type` as `Movable` so the framework can store the result.
trait Transformer(TypedAnnotation):
    comptime In: Base
    comptime Out: Base

    def apply(self, var value: Self.In) raises -> Self.Out:
        ...


# Reads the wire value as `InT` and stores `f(value)` in an `OutT` field:
# `@__annotation(Transform(parse_level)) var level: Int`. Read-only: the
# field is written back as its own type. A raising `f` fails the read with
# `InvalidValue` and the raised text. At most one per field; the field's
# checks run on the converted value.
@fieldwise_init
struct Transform[InT: Base, OutT: Base](Transformer):
    comptime Type = Self.OutT
    comptime In = Self.InT
    comptime Out = Self.OutT
    var f: def(Self.InT) thin raises -> Self.OutT

    def apply(self, var value: Self.In) raises -> Self.Out:
        return self.f(value^)


# Changes what is written for a field: the framework serializes
# `apply(value)` in the field's place. The write-side twin of `Transformer`;
# `SerializeWith` is the stock one.
trait SerializeTransformer(TypedAnnotation):
    comptime Out: Base

    def apply(self, value: Self.Type) raises -> Self.Out:
        ...


# Writes `f(value)` in place of the field:
# `@__annotation(SerializeWith(redact))`. Write-only: the field is read as
# its own type. A raising `f` fails the write with `InvalidValue` and the
# raised text. At most one per field.
@fieldwise_init
struct SerializeWith[InT: AnyType, OutT: Base](SerializeTransformer):
    comptime Type = Self.InT
    comptime Out = Self.OutT
    var f: def(Self.InT) thin raises -> Self.OutT

    def apply(self, value: Self.Type) raises -> Self.Out:
        return self.f(value)


# `value` limited to `[lo, hi]`. Pair it with `Transform` to clamp on read
# instead of rejecting: `@__annotation(Transform(clamp[0, 100]))`.
def clamp[
    T: Comparable & Copyable & Deinitable, //, lo: T, hi: T
](value: T) -> T:
    if value < materialize[lo]():
        return materialize[lo]()
    if value > materialize[hi]():
        return materialize[hi]()
    return value.copy()
