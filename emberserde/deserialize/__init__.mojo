from std.reflection import reflect
from std.builtin.rebind import downcast

from .impls import *
from emberserde.error import DeserializationError, DerErrorKind


# The dual of `Serializable`: a type knows how to build *itself* from a
# deserializer. Serde uses a `Visitor`; Mojo's `comptime if conforms_to` lets the
# type pull values out directly. Mirrors the `Serializable` instance method
# `serialize(self, mut s)` with a static factory.
#
# `Movable` is a supertrait: `deserialize` returns `Self` by value, and the
# recursive container impls must move elements into place. Plain structs opt in
# with a one-liner `return d.expect_struct[Self]()` (see the custom-impl test),
# which routes through the reflection-driven default below.
trait Deserializable(Movable):
    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        ...


trait SeqDerState(ImplicitlyDestructible):
    # True if another element remains; drives the caller's `while` loop.
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    # `AnyType` (not `Movable`): callers pass `reflect[T].field_types()[i]`,
    # whose static bound is `AnyType` even when the concrete field is `Movable`.
    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait MapDerState(ImplicitlyDestructible):
    def has_next(mut self) raises DeserializationError -> Bool:
        ...

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


trait StructDerState(ImplicitlyDestructible):
    def expect_field_name(mut self) raises DeserializationError -> String:
        ...

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        ...

    def end(mut self) raises DeserializationError:
        ...


# Per-format trait. The state types are `comptime` members standing in for
# Mojo's missing associated types (same pattern as `Serializer`). Primitives are
# strict; composites hand back a state struct the caller drives.
trait Deserializer:
    comptime SeqType: SeqDerState
    comptime MapType: MapDerState
    comptime StructType: StructDerState

    def expect_bool(mut self) raises DeserializationError -> Bool:
        ...

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        ...

    def expect_string(mut self) raises DeserializationError -> String:
        ...

    def expect_optional[
        T: Movable
    ](mut self) raises DeserializationError -> Optional[T]:
        ...

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        ...

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        ...

    def begin_struct(mut self) raises DeserializationError -> Self.StructType:
        ...

    def expect_struct[
        T: Defaultable & Movable & ImplicitlyDestructible
    ](mut self) raises DeserializationError -> T:
        comptime r = reflect[T]
        comptime assert r.is_struct(), "expect_struct requires a struct type"
        comptime names = r.field_names()

        var result = T()
        var st = self.begin_struct()

        comptime for _ in range(r.field_count()):
            var name = st.expect_field_name()
            var matched = False
            comptime for i in range(r.field_count()):
                if not matched and name == names[i]:
                    
                    comptime FT = downcast[
                        r.field_types()[i], Movable & ImplicitlyDestructible
                    ]
                    trait_downcast[Movable & ImplicitlyDestructible](
                        r.field_ref[i](result)
                    ) = st.expect_field_value[FT]()
                    matched = True
            if not matched:
                raise DeserializationError(
                    String("unknown field: ") + name, DerErrorKind(0)
                )

        st.end()
        return result^


# Public entry point — the dual of `serialize`. `T` is explicit (unlike
# `serialize`, there is no value argument to infer it from). The `comptime
# assert` defers for an abstract `T` and fires with a readable message at
# instantiation when `T` isn't `Deserializable`.
def deserialize[
    T: AnyType
](mut d: Some[Deserializer]) raises DeserializationError -> T:
    comptime assert conforms_to(T, Deserializable), (
        "type does not conform to Deserializable; a plain struct can implement"
        " it as `return d.expect_struct[Self]()`"
    )
    return T.deserialize(d)
