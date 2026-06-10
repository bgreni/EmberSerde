@fieldwise_init
struct SerErrorKind(ImplicitlyCopyable, Writable):
    var _kind: Int


@fieldwise_init
struct SerializationError(Copyable, Writable):
    var message: String
    var kind: SerErrorKind


@fieldwise_init
struct DerErrorKind(ImplicitlyCopyable, Writable):
    var _kind: Int

    comptime InvalidValue = Self(0)


@fieldwise_init
struct DeserializationError(Copyable, Writable):
    var message: String
    var kind: DerErrorKind
