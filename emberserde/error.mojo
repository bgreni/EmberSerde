@fieldwise_init
struct SerErrorKind(ImplicitlyCopyable, Writable):
    var _kind: Int

    comptime InvalidValue = Self(0)
    comptime Custom = Self(1)


@fieldwise_init
struct SerializationError(Copyable, Writable):
    var message: String
    var kind: SerErrorKind


@fieldwise_init
struct DerErrorKind(ImplicitlyCopyable, Writable):
    var _kind: Int

    comptime InvalidValue = Self(0)
    comptime TypeMismatch = Self(1)
    comptime MissingField = Self(2)
    comptime DuplicateField = Self(3)
    comptime UnknownField = Self(4)
    comptime UnknownVariant = Self(5)
    comptime Custom = Self(6)


@fieldwise_init
struct DeserializationError(Copyable, Writable):
    var message: String
    var kind: DerErrorKind
