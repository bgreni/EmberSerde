@fieldwise_init
struct SerErrorKind(Equatable, ImplicitlyCopyable, Writable):
    var _kind: Int

    comptime InvalidValue = Self(0)
    comptime Custom = Self(1)

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.InvalidValue:
            writer.write("InvalidValue")
        elif self == Self.Custom:
            writer.write("Custom")
        else:
            writer.write("SerErrorKind(", self._kind, ")")


@fieldwise_init
struct SerializationError(Copyable, Writable):
    var message: String
    var kind: SerErrorKind


@fieldwise_init
struct DerErrorKind(Equatable, ImplicitlyCopyable, Writable):
    var _kind: Int

    comptime InvalidValue = Self(0)
    comptime TypeMismatch = Self(1)
    comptime MissingField = Self(2)
    comptime DuplicateField = Self(3)
    comptime UnknownField = Self(4)
    comptime UnknownVariant = Self(5)
    comptime Custom = Self(6)

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.InvalidValue:
            writer.write("InvalidValue")
        elif self == Self.TypeMismatch:
            writer.write("TypeMismatch")
        elif self == Self.MissingField:
            writer.write("MissingField")
        elif self == Self.DuplicateField:
            writer.write("DuplicateField")
        elif self == Self.UnknownField:
            writer.write("UnknownField")
        elif self == Self.UnknownVariant:
            writer.write("UnknownVariant")
        elif self == Self.Custom:
            writer.write("Custom")
        else:
            writer.write("DerErrorKind(", self._kind, ")")


struct DeserializationError(Copyable, Writable):
    var message: String
    var kind: DerErrorKind
    # Wire path to the failure (e.g. `.inner.x` or `[2]`), prepended lazily
    # as the error unwinds through descent sites — the raise site itself pays
    # nothing. Empty when the failure is at the root.
    var path: String

    def __init__(out self, var message: String, kind: DerErrorKind):
        self.message = message^
        self.kind = kind
        self.path = String()

    def prepend_path(mut self, var segment: String):
        segment += self.path
        self.path = segment^

    def write_to(self, mut writer: Some[Writer]):
        if self.path:
            writer.write("at ", self.path, ": ")
        writer.write(self.message, " (", self.kind, ")")
