@fieldwise_init
struct SerErrorKind(Copyable, Writable):
    var _kind: Int


@fieldwise_init
struct SerializationError(Copyable, Writable):
    var message: String
    var kind: SerErrorKind


@fieldwise_init
struct DerErrorKind(Copyable, Writable):
    var _kind: Int


@fieldwise_init
struct DeserializationError(Copyable, Writable):
    var message: String
    var kind: DerErrorKind
