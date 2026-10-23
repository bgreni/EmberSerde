from emberserde.deserialize import (
    EnumDerState,
    MapDerState,
    SeqDerState,
    StructDerState,
    TupleDerState,
)
from emberserde.error import DeserializationError, SerializationError
from emberserde.serialize import (
    EnumSerState,
    MapSerState,
    SeqSerState,
    StructSerState,
    TupleSerState,
)


# The state for a shape a format does not support, opted into explicitly:
# `comptime MapType = Unsupported["maps"]`, with `begin_map` returning
# `Self.MapType()`. Constructing one is the compile error, so it fires only
# where a value of that shape is actually routed through the format; every
# other use of the format still compiles. The state methods assert too, so a
# value made without `__init__` (unsafe allocation, or `deserialize_struct`'s
# constructor-skipping path for non-`Defaultable` structs) still has no
# runtime path. Every assert carries the same message because the compiler
# reports whichever one it reaches first.
struct Unsupported[shape: StaticString](
    EnumDerState,
    EnumSerState,
    MapDerState,
    MapSerState,
    SeqDerState,
    SeqSerState,
    StructDerState,
    StructSerState,
    TupleDerState,
    TupleSerState,
):
    comptime _message = String("format does not support ") + String(Self.shape)

    def __init__(out self):
        comptime assert False, Self._message

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        comptime assert False, Self._message

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        comptime assert False, Self._message

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        comptime assert False, Self._message

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        comptime assert False, Self._message

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        comptime assert False, Self._message

    def has_next(mut self) raises DeserializationError -> Bool:
        comptime assert False, Self._message

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        comptime assert False, Self._message

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        comptime assert False, Self._message

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        comptime assert False, Self._message

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        comptime assert False, Self._message

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        comptime assert False, Self._message

    def skip_value(mut self) raises DeserializationError:
        comptime assert False, Self._message

    def variant_index(mut self) raises DeserializationError -> Int:
        comptime assert False, Self._message

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        comptime assert False, Self._message

    # Non-raising, so the one `end` satisfies both sides' `end`, which
    # differ only in their raise type.
    def end(mut self):
        comptime assert False, Self._message
