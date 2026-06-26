# A non-shipping, test-only *non-self-describing* format (PLAN.md risk #8's
# mitigation): the wire form is a flat `List[String]` of tokens with NO type
# tags, NO field names, and NO container delimiters — reading is driven
# entirely by the type being deserialized, like a bincode-shaped binary
# format. It exists to prove the trait surface works without shape info on
# the wire, which forces three framework features to carry their weight:
#
#   * `begin_seq`/`begin_map` size hints — the count is written up front
#     because nothing on the wire marks where a sequence ends.
#   * `serialize_some` — a present `Optional` writes a `1` presence tag
#     (and `None` writes `0`), because `Some(v)` and bare `v` would
#     otherwise be indistinguishable.
#   * `begin_struct[T]` — field names are never written; the struct state
#     serves them from `reflect[T]` in declaration order so the framework's
#     reflection-driven `expect_struct` default works unchanged.
#
# It follows the same pointer-handle pattern as `_debug_format.mojo`.

from std.reflection import reflect

from emberserde.serialize import (
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.deserialize import (
    Deserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    SerErrorKind,
    DeserializationError,
    DerErrorKind,
)


# ----------------------------------------------------------------------------
# Serialization
# ----------------------------------------------------------------------------


@fieldwise_init
struct TokenSeqSer[origin: MutOrigin](SeqSerState):
    var out: Pointer[List[String], Self.origin]

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


@fieldwise_init
struct TokenMapSer[origin: MutOrigin](MapSerState):
    var out: Pointer[List[String], Self.origin]

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        var sub = TokenSerializer(out=self.out)
        serialize(k, sub)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


@fieldwise_init
struct TokenStructSer[origin: MutOrigin](StructSerState):
    var out: Pointer[List[String], Self.origin]

    def serialize_field(
        mut self, field_name: String, v: Some[AnyType]
    ) raises SerializationError:
        # Field names are not written: the reader recovers them from
        # `reflect[T]` in the same declaration order.
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


# A tuple's length is comptime-known on both ends, so — like a struct — no
# framing is written: just the elements, back to back.
@fieldwise_init
struct TokenTupleSer[origin: MutOrigin](TupleSerState):
    var out: Pointer[List[String], Self.origin]

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


# The discriminant index is written as a token (the arm name is never written),
# then the payload follows — exactly what a bincode-shaped format does.
@fieldwise_init
struct TokenEnumSer[origin: MutOrigin](EnumSerState):
    var out: Pointer[List[String], Self.origin]

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


@fieldwise_init
struct TokenSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[List[String], Self.origin]

    comptime MapType = TokenMapSer[Self.origin]
    comptime SeqType = TokenSeqSer[Self.origin]
    comptime StructType = TokenStructSer[Self.origin]
    comptime TupleType = TokenTupleSer[Self.origin]
    comptime EnumType = TokenEnumSer[Self.origin]

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self.out[].append("true" if v else "false")

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self.out[].append(String(v))

    def serialize_string(mut self, v: String) raises SerializationError:
        self.out[].append(v)

    def serialize_none(mut self) raises SerializationError:
        self.out[].append("0")

    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        # Presence tag: without it `Some(v)` and bare `v` are identical on
        # this wire and `expect_optional` could not decode.
        self.out[].append("1")
        var sub = TokenSerializer(out=self.out)
        serialize(v, sub)

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        if not size_hint:
            raise SerializationError(
                String("token format requires a sequence size hint"),
                SerErrorKind.InvalidValue,
            )
        self.out[].append(String(size_hint.value()))
        return TokenSeqSer(out=self.out)

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        if not size_hint:
            raise SerializationError(
                String("token format requires a map size hint"),
                SerErrorKind.InvalidValue,
            )
        self.out[].append(String(size_hint.value()))
        return TokenMapSer(out=self.out)

    def begin_struct[
        name: String
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        # Nothing on the wire: the field count is comptime-known on both
        # ends via reflection.
        return TokenStructSer(out=self.out)

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        # Nothing on the wire: the arity is comptime-known on both ends.
        return TokenTupleSer(out=self.out)

    def begin_enum[
        name: String, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        # Binary-shaped: write the discriminant index, not the arm name.
        self.out[].append(String(idx))
        return TokenEnumSer(out=self.out)


def to_tokens[
    T: AnyType, //
](value: T) raises SerializationError -> List[String]:
    var buf = List[String]()
    var s = TokenSerializer(out=Pointer(to=buf))
    serialize(value, s)
    return buf^


# ----------------------------------------------------------------------------
# Deserialization
# ----------------------------------------------------------------------------


@fieldwise_init
struct TokenCursor(Movable):
    var tokens: List[String]
    var pos: Int

    def next_token(mut self) raises DeserializationError -> String:
        if self.pos >= len(self.tokens):
            raise DeserializationError(
                String("unexpected end of token stream"),
                DerErrorKind.InvalidValue,
            )
        var tok = self.tokens[self.pos].copy()
        self.pos += 1
        return tok^

    def next_count(mut self) raises DeserializationError -> Int:
        var tok = self.next_token()
        try:
            return Int(atol(tok))
        except e:
            raise DeserializationError(
                String("invalid count token: '") + tok + "'",
                DerErrorKind.InvalidValue,
            )


@fieldwise_init
struct TokenSeqDe[origin: MutOrigin](SeqDerState):
    var cursor: Pointer[TokenCursor, Self.origin]
    var remaining: Int

    def has_next(mut self) raises DeserializationError -> Bool:
        return self.remaining > 0

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        self.remaining -= 1
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TokenMapDe[origin: MutOrigin](MapDerState):
    var cursor: Pointer[TokenCursor, Self.origin]
    var remaining: Int

    def has_next(mut self) raises DeserializationError -> Bool:
        return self.remaining > 0

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.remaining -= 1
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TokenStructDe[origin: MutOrigin](StructDerState):
    var cursor: Pointer[TokenCursor, Self.origin]
    var names: List[String]
    var idx: Int

    def expect_field_name(
        mut self,
    ) raises DeserializationError -> Optional[String]:
        if self.idx >= len(self.names):
            return None
        var name = self.names[self.idx].copy()
        self.idx += 1
        return name^

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        # Unreachable in practice: the names served above come from
        # `reflect[T]`, so the framework never sees an unknown field. A
        # non-self-describing wire genuinely cannot skip a value.
        raise DeserializationError(
            String("token format cannot skip values"),
            DerErrorKind.InvalidValue,
        )

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TokenTupleDe[origin: MutOrigin](TupleDerState):
    var cursor: Pointer[TokenCursor, Self.origin]

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TokenEnumDe[origin: MutOrigin](EnumDerState):
    var cursor: Pointer[TokenCursor, Self.origin]
    var idx: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = TokenDeserializer(cursor=self.cursor)
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TokenDeserializer[origin: MutOrigin](Deserializer):
    var cursor: Pointer[TokenCursor, Self.origin]

    comptime SeqType = TokenSeqDe[Self.origin]
    comptime MapType = TokenMapDe[Self.origin]
    comptime StructType = TokenStructDe[Self.origin]
    comptime TupleType = TokenTupleDe[Self.origin]
    comptime EnumType = TokenEnumDe[Self.origin]

    def expect_bool(mut self) raises DeserializationError -> Bool:
        var tok = self.cursor[].next_token()
        if tok == "true":
            return True
        if tok == "false":
            return False
        raise DeserializationError(
            String("invalid bool token: '") + tok + "'",
            DerErrorKind.TypeMismatch,
        )

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        var tok = self.cursor[].next_token()
        try:
            comptime if DT.is_floating_point():
                return atof(tok).cast[DT]()
            else:
                return Scalar[DT](atol(tok))
        except e:
            raise DeserializationError(
                String("invalid number token: '") + tok + "'",
                DerErrorKind.TypeMismatch,
            )

    def expect_string(mut self) raises DeserializationError -> String:
        return self.cursor[].next_token()

    def expect_optional[
        T: Movable
    ](mut self) raises DeserializationError -> Optional[T]:
        var tag = self.cursor[].next_token()
        if tag == "0":
            return Optional[T]()
        if tag == "1":
            return Optional[T](deserialize[T](self))
        raise DeserializationError(
            String("invalid optional presence tag: '") + tag + "'",
            DerErrorKind.TypeMismatch,
        )

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        return TokenSeqDe(
            cursor=self.cursor, remaining=self.cursor[].next_count()
        )

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        return TokenMapDe(
            cursor=self.cursor, remaining=self.cursor[].next_count()
        )

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        # Nothing on the wire: serve field names from reflection in
        # declaration order so the framework's `expect_struct` default can
        # do its name-matching loop unchanged.
        var names = List[String]()
        comptime r = reflect[T]
        comptime for i in range(r.field_count()):
            names.append(String(r.field_names()[i]))
        return TokenStructDe(cursor=self.cursor, names=names^, idx=0)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        # Nothing on the wire: the arity is comptime-known on both ends.
        return TokenTupleDe(cursor=self.cursor)

    def begin_enum[
        T: AnyType
    ](
        mut self, arm_names: List[String]
    ) raises DeserializationError -> Self.EnumType:
        # Binary-shaped: the discriminant index is read straight off the wire;
        # `arm_names` is unused because the wire carries no name to resolve.
        return TokenEnumDe(cursor=self.cursor, idx=self.cursor[].next_count())


def from_tokens[
    T: AnyType
](var tokens: List[String]) raises DeserializationError -> T:
    var cursor = TokenCursor(tokens^, 0)
    var d = TokenDeserializer(cursor=Pointer(to=cursor))
    return deserialize[T](d)
