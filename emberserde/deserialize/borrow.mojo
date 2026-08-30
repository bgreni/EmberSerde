from emberserde.deserialize import Deserializer
from emberserde.error import DeserializationError


@fieldwise_init
struct RawKind(Equatable, ImplicitlyCopyable, Writable):
    """Which token shape `raw_bytes` must validate before yielding its span.

    Keyed on the data model rather than on a format's syntax, so a binary
    format can honour `Seq`/`Map` as "the encoded bytes of this container"
    without inheriting a text format's vocabulary. `Integer` and `Float`
    mirror the split `expect_number[DT]` already makes by `DType`: a format
    must reject a fractional token under `Integer`.
    """

    var _kind: Int

    comptime Any = Self(0)
    comptime Integer = Self(1)
    comptime Float = Self(2)
    comptime Str = Self(3)
    comptime Seq = Self(4)
    comptime Map = Self(5)

    def __eq__(self, other: Self) -> Bool:
        return self._kind == other._kind

    def __ne__(self, other: Self) -> Bool:
        return self._kind != other._kind

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.Any:
            writer.write("Any")
        elif self == Self.Integer:
            writer.write("Integer")
        elif self == Self.Float:
            writer.write("Float")
        elif self == Self.Str:
            writer.write("Str")
        elif self == Self.Seq:
            writer.write("Seq")
        elif self == Self.Map:
            writer.write("Map")
        else:
            writer.write("RawKind(", self._kind, ")")


trait BorrowingDeserializer(Deserializer):
    """A format that can hand out the raw wire bytes of one value.

    Deferred-parse types (EmberJson's `Lazy`) and whole-input types (its
    tape `Document`) need the bytes of a value without interpreting them.
    This is a sub-trait rather than a defaulted method on `Deserializer` so
    that a format with no byte view simply does not conform, and a type
    requiring one fails at comptime with a readable message instead of
    silently degrading.

    The returned span's origin is **erased**. Mojo traits cannot carry an
    associated origin (a `comptime O: ImmOrigin` is rejected where the
    parameter is used), so the borrowing type re-ties the origin itself:

        return Self(rebind[Span[Byte, Self.o]](d.raw_bytes[Self.kind]()))

    Erasure is confined to that one hop — once re-tied to a tracked origin,
    borrow checking is fully restored and outliving the input is a compile
    error. Implementations must return bytes that live as long as the
    deserializer's own input, never a scratch buffer.

    TODO(parametric traits): the re-tie rebind is an UNCHECKED claim — the
    compiler never verifies the borrowing type's origin parameter matches
    the deserializer's real input origin. Once trait members can bind a
    concrete origin (`Origin[mut, _mlir_origin, //]` is infer-only today,
    so `comptime o: ImmOrigin` fails to infer at every dependent use),
    declare the origin as an associated member, return `Span[Byte, Self.o]`
    directly, and delete the rebinds in borrowing types (e.g. EmberJson's
    `Lazy.deserialize`) — turning that claim into a compile-checked one.
    """

    def raw_bytes[
        kind: RawKind
    ](mut self) raises DeserializationError -> Span[Byte, ImmUntrackedOrigin]:
        """Consumes one value and returns its raw wire bytes.

        Raises if the next value is not of `kind`. The span covers the whole
        token as written, including any delimiters a text format uses (a
        string's quotes are part of it).
        """
        ...
