from .deserialize import (
    Deserializable,
    DeserializationError,
    Deserializer,
    deserialize,
)
from .serialize import Serializable, SerializationError, Serializer, serialize
from .field_meta import FieldMeta
from .utils import Base


comptime Defaulted[T: Base, value: T] = Field[T, default=value]
comptime Skip[T: Base] = Field[T, skip=True]
comptime Rename[T: Base, s: String] = Field[T, rename=s]


@always_inline
def __just_true[T: Base](t: T) -> Bool:
    return True


struct Field[
    T: Base,
    *,
    rename: Optional[String] = None,
    extra_names: Optional[List[String]] = None,
    skip: Bool = False,
    # skip_if: def(T) -> Bool = __just_true[T],
    default: Optional[T] = None,
](
    Copyable where conforms_to(T, Copyable),
    Defaultable where conforms_to(T, Defaultable),
    Deserializable,
    FieldMeta,
    Serializable,
):
    comptime serde_name = Self.rename
    comptime serde_extra = Self.extra_names
    comptime serde_skip = Self.skip
    comptime serde_fill_if_missing = Self.skip or Bool(Self.default)

    var value: Self.T

    # Used by the reflection default to materialize a skipped/defaulted field
    # that is absent from the wire: the `default` value if given, else `T()`.
    def __init__(out self):
        comptime if Self.default:
            self.value = materialize[Self.default.value()]()
        elif conforms_to(Self.T, Defaultable):
            self.value = Self.T()
        else:
            comptime assert False, (
                "Cannot default construct with type that is not defaultable,"
                " nor has a given default value"
            )

    @implicit
    def __init__(out self, var value: Self.T):
        self.value = value^

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        serialize(self.value, s)

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return {deserialize[Self.T](d)}
