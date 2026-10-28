# A non-shipping, test-only protobuf format (proto3 binary encoding) that
# reads and writes exactly what upb, the reference implementation behind
# Python's protobuf, does. Every struct read first gathers each field's
# occurrences, and the framework does one fresh read per field; which merge
# rule applies falls out of what the field's type asks for: a scalar takes
# the last occurrence, a message reads all of them as one concatenated
# message (protobuf defines its merge as exactly that), a seq or map takes
# each as an element/entry.
#
# Wire form:
#   * Field numbers: `ProtoTag(n)`, else declaration index + 1.
#   * Integers are varints (negative int32/int64 sign-extended to 10 bytes),
#     `ZigZag()` makes them sint, `Fixed()` fixed32/fixed64 by width. Floats
#     are fixed32/fixed64, `Bool` a varint, strings and bytes length-delimited.
#   * Plain fields have implicit presence: a zero/empty value is not written
#     and an absent field reads as zero. `Optional` (and a `Default`-carrying
#     field) has explicit presence; a proto3 message field is an `Optional`
#     struct. Messages are always written.
#   * Scalar seqs are written packed; both packed and unpacked are read.
#     Maps are repeated `{1: key, 2: value}` entry messages.
#   * A `Variant` field annotated `ProtoOneof[n0, n1, ...]()` is a oneof whose
#     arm i is field number n_i. A seq, map, `Optional` or other `Variant` that
#     is not itself a struct field (a nested list, a list element, the root)
#     is boxed in a message holding it as field 1 (a `Variant`'s arm i as
#     field i + 1). Tuples are messages with fields 1..n.
#   * Fields are written in field-number order, then the unknown fields.
#
# Reading follows upb wherever the spec leaves room: a field of the wrong
# wire type is an unknown field, unknown groups are skipped, a malformed map
# entry moves into the unknown fields, tags are at most 5 bytes with numbers
# below 2^29, nesting stops at 100 levels, and every occurrence is validated
# even when a later one overwrites it. A struct keeps its unknown fields only
# if it has an `UnknownFields` field; a custom `Deserializable` that reads a
# scalar must conform to `ProtoType` to say so.

from std.builtin.rebind import downcast
from std.collections import Counter, Deque, LinkedList, Set
from std.collections.string import Codepoint
from std.memory import ArcPointer, OwnedPointer, bitcast
from std.reflection import reflect
from std.sys.info import bit_width_of
from std.utils import Variant

from emberserde.serialize import (
    Serializable,
    Serializer,
    SeqSerState,
    MapSerState,
    StructSerState,
    TupleSerState,
    EnumSerState,
    serialize,
)
from emberserde.deserialize import (
    Deserializable,
    Deserializer,
    SeqDerState,
    MapDerState,
    StructDerState,
    TupleDerState,
    EnumDerState,
    deserialize,
    may_be_absent,
)
from emberserde.error import (
    SerializationError,
    SerErrorKind,
    DeserializationError,
    DerErrorKind,
)
from emberserde.field import Default
from emberserde.field_meta import count_annotations, field_annotations
from emberserde.struct_modifiers import (
    DenyUnknownFields,
    count_struct_annotations,
)
from emberserde.utils import Base


comptime _VARINT = 0
comptime _I64 = 1
comptime _LEN = 2
comptime _SGROUP = 3
comptime _EGROUP = 4
comptime _I32 = 5

comptime _MAX_NUMBER = (1 << 29) - 1

comptime _ENC_VARINT = 0
comptime _ENC_ZIGZAG = 1
comptime _ENC_FIXED = 2


@fieldwise_init
struct ProtoTag(Base):
    var number: Int


@fieldwise_init
struct ZigZag(Base):
    pass


@fieldwise_init
struct Fixed(Base):
    pass


trait OneofNumbers(Base):
    @staticmethod
    def numbers() -> List[Int]:
        ...


struct ProtoOneof[*nums: Int](OneofNumbers):
    def __init__(out self):
        pass

    @staticmethod
    def numbers() -> List[Int]:
        var result = List[Int]()
        comptime for k in range(len(Self.nums)):
            result.append(Self.nums[k])
        return result^


def _number[T: AnyType, i: Int]() -> Int:
    comptime anns = field_annotations[T, i]
    comptime Ts = type_of(anns).Ts
    comptime for j in range(Ts.length):
        comptime if Ts[j] == ProtoTag:
            comptime n = rebind[ProtoTag](anns[j]).number
            return n
    return i + 1


def _encoding[T: AnyType, i: Int]() -> Int:
    comptime if count_annotations[T, i, ZigZag]() > 0:
        return _ENC_ZIGZAG
    elif count_annotations[T, i, Fixed]() > 0:
        return _ENC_FIXED
    return _ENC_VARINT


# A oneof field's member numbers, empty for any other field.
def _oneof[T: AnyType, i: Int]() -> List[Int]:
    comptime Ts = type_of(field_annotations[T, i]).Ts
    comptime for j in range(Ts.length):
        comptime if conforms_to(Ts[j], OneofNumbers):
            return downcast[Ts[j], OneofNumbers].numbers()
    return []


# Every wire number that binds field `i`.
def _numbers_of[T: AnyType, i: Int]() -> List[Int]:
    comptime if _is_store[T, i]():
        return []
    var ns = _oneof[T, i]()
    if not ns:
        ns.append(_number[T, i]())
    return ns^


# A message's unknown fields, in wire order, so that re-serializing it keeps
# them as the reference implementations do. A struct opts in with one field
# of this type; it takes no field number.
@fieldwise_init
struct UnknownFields(
    Copyable, Defaultable, Deserializable, Movable, Serializable, _Store
):
    var bytes: List[UInt8]

    def __init__(out self):
        self.bytes = []

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_bytes())

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_bytes(Span(self.bytes))


trait _Store:
    pass


def _is_store[T: AnyType, i: Int]() -> Bool:
    return conforms_to(reflect[T].field_types()[i], _Store)


comptime _M_VARINT = 1 << _VARINT
comptime _M_I64 = 1 << _I64
comptime _M_LEN = 1 << _LEN
comptime _M_I32 = 1 << _I32


# What a value of some type is on the wire. Occurrences whose wire type is not
# in `mask` are unknown fields, as in the reference parser, and so are map
# entries whose fields miss `key_mask`/`value_mask`.
@fieldwise_init
struct Desc(Copyable, Movable):
    var mask: Int
    # A seq of scalars: a length-delimited occurrence is a packed run.
    var packed: Bool
    # Outside a field position it is boxed in a message (`_element_desc`).
    var boxed: Bool
    var key_mask: Int
    var value_mask: Int
    # A `Variant`: each arm's mask, in arm order.
    var arms: List[Int]


def _scalar_desc(mask: Int) -> Desc:
    return Desc(mask, False, False, 0, 0, [])


def _message_desc() -> Desc:
    return _scalar_desc(_M_LEN)


def _seq_desc(elem: Desc) -> Desc:
    if elem.mask == _M_LEN:
        return Desc(_M_LEN, False, True, 0, 0, [])
    return Desc(elem.mask | _M_LEN, True, True, 0, 0, [])


# A type's wire shape in a field position, with integer encoding `enc`. A type
# that doesn't conform to `ProtoType` is a message, so a custom
# `Deserializable` that reads a scalar must conform to say so.
trait ProtoType:
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        ...


# A oneof: reads the occurrences `run` of arm `arm` and discards the value.
# upb parses a member before a later one clears it, so a malformed cleared
# member still fails the parse.
trait ProtoOneofArms:
    @staticmethod
    def check_arm[
        o: MutOrigin
    ](
        arm: Int,
        buf: Pointer[List[UInt8], o],
        var run: List[Occ],
        enc: Int,
        depth: Int,
    ) raises DeserializationError:
        ...


# A map field: its malformed `entry`, written back as upb does when it moves
# one into the unknown fields.
trait ProtoMap:
    @staticmethod
    def reencode_entry[
        o: MutOrigin
    ](
        buf: Pointer[List[UInt8], o],
        entry: Occ,
        enc: Int,
        depth: Int,
    ) raises DeserializationError -> List[UInt8]:
        ...


def _desc_of[T: AnyType](enc: Int) -> Desc:
    comptime if conforms_to(T, ProtoType):
        return downcast[T, ProtoType].proto_desc(enc)
    else:
        return _message_desc()


# Outside a field position (a list element, a tuple element, the root) a
# seq, map, `Optional` or `Variant` is boxed in a message.
def _element_desc[T: AnyType](enc: Int) -> Desc:
    var d = _desc_of[T](enc)
    if d.boxed:
        return _message_desc()
    return d^


def _int_desc[dt: DType](enc: Int) -> Desc:
    if enc == _ENC_FIXED:
        comptime if bit_width_of[dt]() <= 32:
            return _scalar_desc(_M_I32)
        else:
            return _scalar_desc(_M_I64)
    return _scalar_desc(_M_VARINT)


__extension SIMD(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        comptime if Self.length != 1:
            return _message_desc()
        elif Self.dtype == DType.float32:
            return _scalar_desc(_M_I32)
        elif Self.dtype == DType.float64:
            return _scalar_desc(_M_I64)
        elif Self.dtype == DType.bool:
            return _scalar_desc(_M_VARINT)
        else:
            return _int_desc[Self.dtype](enc)


__extension Bool(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _scalar_desc(_M_VARINT)


__extension Codepoint(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _int_desc[DType.uint32](enc)


__extension List(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _seq_desc(_element_desc[Self.T](enc))


__extension Set(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _seq_desc(_element_desc[Self.T](enc))


__extension Deque(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _seq_desc(_element_desc[Self.ElementType](enc))


__extension LinkedList(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _seq_desc(_element_desc[Self.ElementType](enc))


__extension Dict(ProtoMap, ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return Desc(
            _M_LEN,
            False,
            True,
            _desc_of[Self.K](enc).mask,
            _desc_of[Self.V](enc).mask,
            [],
        )

    @staticmethod
    def reencode_entry[
        o: MutOrigin
    ](
        buf: Pointer[List[UInt8], o],
        entry: Occ,
        enc: Int,
        depth: Int,
    ) raises DeserializationError -> List[UInt8]:
        comptime assert conforms_to(Self.K, Base) and conforms_to(
            Self.V, Base
        ), "map keys and values must be Movable & Deinitable"
        return _reencode_entry[downcast[Self.K, Base], downcast[Self.V, Base]](
            buf, entry, enc, depth
        )


__extension Counter(ProtoMap, ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return Desc(
            _M_LEN,
            False,
            True,
            _desc_of[Self.V](enc).mask,
            _desc_of[Int](enc).mask,
            [],
        )

    @staticmethod
    def reencode_entry[
        o: MutOrigin
    ](
        buf: Pointer[List[UInt8], o],
        entry: Occ,
        enc: Int,
        depth: Int,
    ) raises DeserializationError -> List[UInt8]:
        comptime assert conforms_to(
            Self.V, Base
        ), "map keys must be Movable & Deinitable"
        return _reencode_entry[downcast[Self.V, Base], Int](
            buf, entry, enc, depth
        )


__extension Optional(ProtoMap, ProtoOneofArms, ProtoType):
    @staticmethod
    def check_arm[
        o: MutOrigin
    ](
        arm: Int,
        buf: Pointer[List[UInt8], o],
        var run: List[Occ],
        enc: Int,
        depth: Int,
    ) raises DeserializationError:
        comptime if conforms_to(Self.T, ProtoOneofArms):
            downcast[Self.T, ProtoOneofArms].check_arm(
                arm, buf, run^, enc, depth
            )

    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        var d = _desc_of[Self.T](enc)
        d.boxed = True
        return d^

    @staticmethod
    def reencode_entry[
        o: MutOrigin
    ](
        buf: Pointer[List[UInt8], o],
        entry: Occ,
        enc: Int,
        depth: Int,
    ) raises DeserializationError -> List[UInt8]:
        comptime if conforms_to(Self.T, ProtoMap):
            return downcast[Self.T, ProtoMap].reencode_entry(
                buf, entry, enc, depth
            )
        else:
            return []


__extension Variant(ProtoOneofArms, ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        var arms = List[Int]()
        comptime for i in range(Self.Ts.length):
            arms.append(_desc_of[Self.Ts[i]](enc).mask)
        return Desc(_M_LEN, False, True, 0, 0, arms^)

    @staticmethod
    def check_arm[
        o: MutOrigin
    ](
        arm: Int,
        buf: Pointer[List[UInt8], o],
        var run: List[Occ],
        enc: Int,
        depth: Int,
    ) raises DeserializationError:
        comptime for i in range(Self.Ts.length):
            comptime AT = Self.Ts[i]
            if arm == i:
                var sub = ProtoDeserializer[o].of_field(
                    buf, run^, enc, [], _desc_of[AT](enc), depth
                )
                comptime assert conforms_to(
                    AT, Base
                ), "Variant arms must be Movable & Deinitable"
                _ = deserialize[downcast[AT, Base]](sub)
                return


__extension OwnedPointer(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _desc_of[Self.T](enc)


__extension ArcPointer(ProtoType):
    @staticmethod
    def proto_desc(enc: Int) -> Desc:
        return _desc_of[Self.T](enc)


def _unique_numbers[T: AnyType]() -> Bool:
    var seen = List[Int]()
    comptime for i in range(reflect[T].field_count()):
        var ns = _numbers_of[T, i]()
        for n in ns:
            if n in seen or n < 1 or n > _MAX_NUMBER:
                return False
            seen.append(n)
    return True


def _store_count[T: AnyType]() -> Int:
    var n = 0
    comptime for i in range(reflect[T].field_count()):
        comptime if _is_store[T, i]():
            n += 1
    return n


# A field with a `Default` reads back as that value when absent, so it can't
# use implicit presence's "zero is not written".
def _explicit[T: AnyType, i: Int]() -> Bool:
    comptime FT = reflect[T].field_types()[i]
    return count_annotations[T, i, Default[downcast[FT, Base]]]() > 0


@no_inline
def _invalid(message: StaticString) -> DeserializationError:
    return DeserializationError(String(message), DerErrorKind.InvalidValue)


@no_inline
def _mismatch(message: StaticString) -> DeserializationError:
    return DeserializationError(String(message), DerErrorKind.TypeMismatch)


@no_inline
def _absent() -> DeserializationError:
    return DeserializationError(
        String("missing field: no oneof member is set"),
        DerErrorKind.MissingField,
    )


# ----------------------------------------------------------------------------
# Serialization
# ----------------------------------------------------------------------------


def _put_varint(mut out: List[UInt8], var v: UInt64):
    while v >= 0x80:
        out.append((v & 0x7F).cast[DType.uint8]() | 0x80)
        v >>= 7
    out.append(v.cast[DType.uint8]())


def _put_tag(mut out: List[UInt8], number: Int, wt: Int):
    _put_varint(out, (UInt64(number) << 3) | UInt64(wt))


def _put_raw(mut out: List[UInt8], wt: Int, bits: UInt64):
    if wt == _VARINT:
        _put_varint(out, bits)
        return
    var n = 4 if wt == _I32 else 8
    for k in range(n):
        out.append((bits >> UInt64(8 * k)).cast[DType.uint8]())


def _put_len(mut out: List[UInt8], number: Int, body: Span[Byte, _]):
    _put_tag(out, number, _LEN)
    _put_varint(out, UInt64(len(body)))
    out.extend(body)


@fieldwise_init
struct _Raw(ImplicitlyCopyable, Movable):
    var wt: Int
    var bits: UInt64


def _to_raw[dt: DType](v: Scalar[dt], enc: Int) -> _Raw:
    comptime if dt == DType.float32:
        return _Raw(_I32, v.to_bits[DType.uint64]())
    elif dt == DType.float64:
        return _Raw(_I64, v.to_bits[DType.uint64]())
    else:
        var bits: UInt64
        comptime if dt.is_signed():
            var n = v.cast[DType.int64]()
            if enc == _ENC_ZIGZAG:
                return _Raw(
                    _VARINT, bitcast[DType.uint64]((n << 1) ^ (n >> 63))
                )
            bits = bitcast[DType.uint64](n)
        else:
            bits = v.cast[DType.uint64]()
        if enc == _ENC_FIXED:
            comptime if bit_width_of[dt]() <= 32:
                return _Raw(_I32, bits & 0xFFFFFFFF)
            else:
                return _Raw(_I64, bits)
        return _Raw(_VARINT, bits)


# The serializer for one value. In a FIELD position (`field`) it writes
# tagged occurrences of `number` straight into the enclosing message;
# anywhere else it writes the bare value and records its wire type in
# `wire`, so the caller (a seq, or the root) decides on the framing.
@fieldwise_init
struct ProtoSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[List[UInt8], Self.origin]
    var number: Int
    var field: Bool
    var implicit: Bool
    var enc: Int
    var oneof: List[Int]
    var wire: Int

    comptime MapType = ProtoMapSer[Self.origin]
    comptime SeqType = ProtoSeqSer[Self.origin]
    comptime StructType = ProtoStructSer[Self.origin]
    comptime TupleType = ProtoTupleSer[Self.origin]
    comptime EnumType = ProtoEnumSer[Self.origin]

    def _scalar(mut self, r: _Raw):
        self.wire = r.wt
        if self.field:
            if self.implicit and r.bits == 0:
                return
            _put_tag(self.out[], self.number, r.wt)
        _put_raw(self.out[], r.wt, r.bits)

    def _bytes(mut self, v: Span[Byte, _]):
        self.wire = _LEN
        if not self.field:
            self.out[].extend(Span(v))
        elif not (self.implicit and len(v) == 0):
            _put_len(self.out[], self.number, v)

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self._scalar(_Raw(_VARINT, UInt64(1) if v else UInt64(0)))

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self._scalar(_to_raw(v, self.enc))

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self._bytes(v.as_bytes())

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        self._bytes(v)

    # Out of a field position the empty box is the `None`.
    def serialize_none(mut self) raises SerializationError:
        self.wire = _LEN

    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        if self.field:
            var sub = ProtoSerializer(
                out=self.out,
                number=self.number,
                field=True,
                implicit=False,
                enc=self.enc,
                oneof=self.oneof.copy(),
                wire=-1,
            )
            serialize(v, sub)
        else:
            self.wire = _LEN
            var sub = ProtoSerializer(
                out=self.out,
                number=1,
                field=True,
                implicit=False,
                enc=self.enc,
                oneof=[],
                wire=-1,
            )
            serialize(v, sub)

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        if self.field:
            return ProtoSeqSer(
                out=self.out, number=self.number, enc=self.enc, packed=[]
            )
        self.wire = _LEN
        return ProtoSeqSer(out=self.out, number=1, enc=self.enc, packed=[])

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        if self.field:
            return ProtoMapSer(
                out=self.out, number=self.number, enc=self.enc, entry=[]
            )
        self.wire = _LEN
        return ProtoMapSer(out=self.out, number=1, enc=self.enc, entry=[])

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        comptime assert _unique_numbers[T](), (
            "two fields share a protobuf field number, or one is outside"
            " 1..2^29-1"
        )
        comptime assert (
            _store_count[T]() <= 1
        ), "a message may hold at most one UnknownFields"
        if self.field:
            return ProtoStructSer(
                out=self.out, number=self.number, chunks=[], unknown=[]
            )
        self.wire = _LEN
        return ProtoStructSer(out=self.out, number=-1, chunks=[], unknown=[])

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        if self.field:
            return ProtoTupleSer(
                out=self.out, number=self.number, body=[], next=1
            )
        self.wire = _LEN
        return ProtoTupleSer(out=self.out, number=-1, body=[], next=1)

    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        var arm = Int(idx)
        if self.field and self.oneof:
            if arm >= len(self.oneof):
                raise SerializationError(
                    String("ProtoOneof lists fewer numbers than the arms"),
                    SerErrorKind.InvalidValue,
                )
            return ProtoEnumSer(
                out=self.out,
                body=[],
                payload_number=self.oneof[arm],
                wrap_number=-1,
                enc=self.enc,
            )
        if self.field:
            return ProtoEnumSer(
                out=self.out,
                body=[],
                payload_number=arm + 1,
                wrap_number=self.number,
                enc=self.enc,
            )
        self.wire = _LEN
        return ProtoEnumSer(
            out=self.out,
            body=[],
            payload_number=arm + 1,
            wrap_number=-1,
            enc=self.enc,
        )


# Packed scalars collect in `packed` and are written as one occurrence at
# `end`; anything length-delimited is its own occurrence.
@fieldwise_init
struct ProtoSeqSer[origin: MutOrigin](SeqSerState):
    var out: Pointer[List[UInt8], Self.origin]
    var number: Int
    var enc: Int
    var packed: List[UInt8]

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var tmp = List[UInt8]()
        var sub = ProtoSerializer(
            out=Pointer(to=tmp),
            number=0,
            field=False,
            implicit=False,
            enc=self.enc,
            oneof=[],
            wire=-1,
        )
        serialize(v, sub)
        if sub.wire == _LEN:
            _put_len(self.out[], self.number, Span(tmp))
        else:
            self.packed.extend(Span(tmp))

    def end(mut self) raises SerializationError:
        if self.packed:
            _put_len(self.out[], self.number, Span(self.packed))


@fieldwise_init
struct ProtoMapSer[origin: MutOrigin](MapSerState):
    var out: Pointer[List[UInt8], Self.origin]
    var number: Int
    var enc: Int
    var entry: List[UInt8]

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        self.entry.clear()
        var sub = ProtoSerializer(
            out=Pointer(to=self.entry),
            number=1,
            field=True,
            implicit=False,
            enc=self.enc,
            oneof=[],
            wire=-1,
        )
        serialize(k, sub)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = ProtoSerializer(
            out=Pointer(to=self.entry),
            number=2,
            field=True,
            implicit=False,
            enc=self.enc,
            oneof=[],
            wire=-1,
        )
        serialize(v, sub)
        _put_len(self.out[], self.number, Span(self.entry))

    def end(mut self) raises SerializationError:
        pass


# Each field's bytes collect separately so `end` can write them in
# field-number order, as the reference serializer does, with the unknown
# fields last. `number` -1 writes the body bare (the root, or a list element
# whose seq adds the framing).
@fieldwise_init
struct ProtoStructSer[origin: MutOrigin](StructSerState):
    var out: Pointer[List[UInt8], Self.origin]
    var number: Int
    var chunks: List[List[UInt8]]
    var unknown: List[UInt8]

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        comptime if _is_store[T, idx]():
            var sub = ProtoSerializer(
                out=Pointer(to=self.unknown),
                number=0,
                field=False,
                implicit=False,
                enc=_ENC_VARINT,
                oneof=[],
                wire=-1,
            )
            serialize(v, sub)
        else:
            var chunk = List[UInt8]()
            var sub = ProtoSerializer(
                out=Pointer(to=chunk),
                number=_number[T, idx](),
                field=True,
                implicit=not _explicit[T, idx](),
                enc=_encoding[T, idx](),
                oneof=_oneof[T, idx](),
                wire=-1,
            )
            serialize(v, sub)
            if chunk:
                self.chunks.append(chunk^)

    def end(mut self) raises SerializationError:
        var order = List[Int]()
        for k in range(len(self.chunks)):
            var at = len(order)
            while at > 0 and _first_number(
                self.chunks[order[at - 1]]
            ) > _first_number(self.chunks[k]):
                at -= 1
            order.insert(at, k)
        var body = List[UInt8]()
        for k in order:
            body.extend(Span(self.chunks[k]))
        body.extend(Span(self.unknown))
        if self.number < 0:
            self.out[].extend(Span(body))
        else:
            _put_len(self.out[], self.number, Span(body))


# The field number of the first tag in a field's serialized bytes.
def _first_number(chunk: List[UInt8]) -> Int:
    var key = 0
    var shift = 0
    for b in chunk:
        key |= Int(b & 0x7F) << shift
        if b < 0x80:
            break
        shift += 7
    return key >> 3


@fieldwise_init
struct ProtoTupleSer[origin: MutOrigin](TupleSerState):
    var out: Pointer[List[UInt8], Self.origin]
    var number: Int
    var body: List[UInt8]
    var next: Int

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = ProtoSerializer(
            out=Pointer(to=self.body),
            number=self.next,
            field=True,
            implicit=True,
            enc=_ENC_VARINT,
            oneof=[],
            wire=-1,
        )
        self.next += 1
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        if self.number < 0:
            self.out[].extend(Span(self.body))
        else:
            _put_len(self.out[], self.number, Span(self.body))


# A oneof member, or an arm inside a box: the payload is a field of
# `payload_number`. `wrap_number` -1 writes it straight into `out`.
@fieldwise_init
struct ProtoEnumSer[origin: MutOrigin](EnumSerState):
    var out: Pointer[List[UInt8], Self.origin]
    var body: List[UInt8]
    var payload_number: Int
    var wrap_number: Int
    var enc: Int

    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        if self.wrap_number < 0:
            var sub = ProtoSerializer(
                out=self.out,
                number=self.payload_number,
                field=True,
                implicit=False,
                enc=self.enc,
                oneof=[],
                wire=-1,
            )
            serialize(v, sub)
        else:
            var sub = ProtoSerializer(
                out=Pointer(to=self.body),
                number=self.payload_number,
                field=True,
                implicit=False,
                enc=self.enc,
                oneof=[],
                wire=-1,
            )
            serialize(v, sub)

    def end(mut self) raises SerializationError:
        if self.wrap_number >= 0:
            _put_len(self.out[], self.wrap_number, Span(self.body))


def to_proto[T: AnyType, //](value: T) raises SerializationError -> List[UInt8]:
    var buf = List[UInt8]()
    var s = ProtoSerializer(
        out=Pointer(to=buf),
        number=0,
        field=False,
        implicit=False,
        enc=_ENC_VARINT,
        oneof=[],
        wire=-1,
    )
    serialize(value, s)
    return buf^


# ----------------------------------------------------------------------------
# Deserialization
# ----------------------------------------------------------------------------


# Nesting deeper than this is an error, as in upb: each message, map entry,
# group, box and tuple is a level.
comptime _MAX_DEPTH = 100


def _put_entry_part[
    T: AnyType
](
    mut body: List[UInt8], number: Int, value: T, enc: Int
) raises DeserializationError:
    var sub = ProtoSerializer(
        out=Pointer(to=body),
        number=number,
        field=True,
        implicit=True,
        enc=enc,
        oneof=[],
        wire=-1,
    )
    try:
        serialize(value, sub)
    except e:
        raise DeserializationError(e.message, DerErrorKind.InvalidValue)


# A malformed map entry as upb writes it back: parsed as an ordinary
# `{1: key, 2: value}` message, so the last key wins, a split value merges,
# zero values drop out and varints come out minimal, then its unknown fields
# in wire order.
def _reencode_entry[
    K: Base, V: Base, o: MutOrigin
](
    buf: Pointer[List[UInt8], o], entry: Occ, enc: Int, depth: Int
) raises DeserializationError -> List[UInt8]:
    var kd = _desc_of[K](enc)
    var vd = _desc_of[V](enc)
    var keys = List[Occ]()
    var values = List[Occ]()
    var rest = List[UInt8]()
    var pos = entry.start
    while pos < entry.end:
        var f = _read_occ(buf[], pos, entry.end, depth)
        if f.number == 1 and _accepts(kd.mask, f.wt):
            keys.append(f)
        elif f.number == 2 and _accepts(vd.mask, f.wt):
            values.append(f)
        else:
            rest.extend(Span(buf[])[f.raw_start : f.raw_end])
    var body = List[UInt8]()
    if keys:
        var kv = ProtoDeserializer[o].of_field(buf, keys^, enc, [], kd^, depth)
        _put_entry_part(body, 1, deserialize[K](kv), enc)
    if values:
        var vv = ProtoDeserializer[o].of_field(
            buf, values^, enc, [], vd^, depth
        )
        _put_entry_part(body, 2, deserialize[V](vv), enc)
    body.extend(Span(rest))
    var out = List[UInt8]()
    _put_len(out, entry.number, Span(body))
    return out^


# One occurrence: the value bytes `[start, end)` of wire type `wt` (a
# length-delimited value's payload, a group's contents), tagged `number`.
# `[raw_start, raw_end)` is the whole tagged field, which an unknown field
# keeps.
@fieldwise_init
struct Occ(ImplicitlyCopyable, Movable):
    var wt: Int
    var start: Int
    var end: Int
    var number: Int
    var raw_start: Int
    var raw_end: Int


def _varint(
    buf: List[UInt8], mut pos: Int, limit: Int
) raises DeserializationError -> UInt64:
    var v = UInt64(0)
    for shift in range(0, 70, 7):
        if pos >= limit:
            raise _invalid("truncated varint")
        var b = buf[pos]
        pos += 1
        v |= (b & 0x7F).cast[DType.uint64]() << UInt64(shift)
        if b < 0x80:
            return v
    raise _invalid("varint longer than 10 bytes")


def _raw(buf: List[UInt8], o: Occ) raises DeserializationError -> UInt64:
    var pos = o.start
    if o.wt == _VARINT:
        return _varint(buf, pos, o.end)
    if o.wt != _I32 and o.wt != _I64:
        raise _mismatch("expected a scalar, found a length-delimited value")
    var v = UInt64(0)
    for k in range(o.end - o.start):
        v |= buf[o.start + k].cast[DType.uint64]() << UInt64(8 * k)
    return v


# Narrower integers truncate, as protobuf's own parsers do: an int32 is
# written as its sign-extended int64.
def _from_raw[
    DT: DType
](bits: UInt64, wt: Int, enc: Int) raises DeserializationError -> Scalar[DT]:
    comptime if DT == DType.float32:
        if wt != _I32:
            raise _mismatch("expected fixed32 for a float")
        return bitcast[DType.float32](bits.cast[DType.uint32]()).cast[DT]()
    elif DT == DType.float64:
        if wt != _I64:
            raise _mismatch("expected fixed64 for a double")
        return bitcast[DType.float64](bits).cast[DT]()
    else:
        if enc == _ENC_ZIGZAG and wt == _VARINT:
            # sint32 truncates to 32 bits before decoding, as upb does.
            comptime if bit_width_of[DT]() <= 32:
                var b = bits.cast[DType.uint32]()
                var low = (b & 1).cast[DType.int32]()
                return ((b >> 1).cast[DType.int32]() ^ -low).cast[DT]()
            else:
                var low = (bits & 1).cast[DType.int64]()
                return ((bits >> 1).cast[DType.int64]() ^ -low).cast[DT]()
        comptime if DT.is_signed():
            if wt == _I32:
                return bitcast[DType.int32](bits.cast[DType.uint32]()).cast[
                    DT
                ]()
            return bitcast[DType.int64](bits).cast[DT]()
        return bits.cast[DT]()


# The wire type each element of a packed run of `DT` has.
def _packed_wire[DT: DType](enc: Int) -> Int:
    comptime if DT == DType.float32:
        return _I32
    elif DT == DType.float64:
        return _I64
    if enc == _ENC_FIXED:
        comptime if bit_width_of[DT]() <= 32:
            return _I32
        else:
            return _I64
    return _VARINT


# The tagged value at `pos`, which then points past it.
def _utf8(bytes: Span[Byte, _]) raises DeserializationError -> String:
    try:
        return String(from_utf8=bytes)
    except:
        raise _invalid("string is not valid UTF-8")


@no_inline
def _too_deep() -> DeserializationError:
    return _invalid("nesting exceeds the depth limit")


# The tagged field at `pos`, which then points past it; `depth` is the level
# of the message holding it. A group is skipped whole, each nested group a
# level deeper; an end-group tag outside its group is an error.
def _read_occ(
    buf: List[UInt8], mut pos: Int, end: Int, depth: Int
) raises DeserializationError -> Occ:
    var raw_start = pos
    var key = _varint(buf, pos, end)
    if pos - raw_start > 5 or key > 0xFFFFFFFF:
        raise _invalid("malformed tag")
    var number = Int(key >> 3)
    var wt = Int(key & 7)
    if number == 0:
        raise _invalid("field number 0")
    var start = pos
    if wt == _VARINT:
        _ = _varint(buf, pos, end)
    elif wt == _I64:
        pos += 8
    elif wt == _I32:
        pos += 4
    elif wt == _LEN:
        var size = _varint(buf, pos, end)
        if size > UInt64(end - pos):
            raise _invalid("length-delimited value overruns its message")
        start = pos
        pos += Int(size)
    elif wt == _SGROUP:
        if depth + 1 > _MAX_DEPTH:
            raise _too_deep()
        while True:
            if pos >= end:
                raise _invalid("unterminated group")
            var at = pos
            var inner = _varint(buf, pos, end)
            if Int(inner & 7) == _EGROUP:
                if pos - at > 5 or Int(inner >> 3) != number:
                    raise _invalid("mismatched end-group tag")
                return Occ(wt, start, at, number, raw_start, pos)
            pos = at
            _ = _read_occ(buf, pos, end, depth + 1)
    else:
        raise _invalid("malformed wire type")
    if pos > end:
        raise _invalid("value overruns its message")
    return Occ(wt, start, pos, number, raw_start, pos)


def _accepts(mask: Int, wt: Int) -> Bool:
    return (mask >> wt) & 1 == 1


def _filter(occs: List[Occ], mask: Int) -> List[Occ]:
    var kept = List[Occ]()
    for o in occs:
        if _accepts(mask, o.wt):
            kept.append(o)
    return kept^


# Whether every field of a map entry is a key or value of the expected wire
# type. upb moves any other entry, whole, into the unknown fields.
def _entry_ok(
    buf: List[UInt8], entry: Occ, key_mask: Int, value_mask: Int, depth: Int
) raises DeserializationError -> Bool:
    if depth > _MAX_DEPTH:
        raise _too_deep()
    var ok = True
    var pos = entry.start
    while pos < entry.end:
        var f = _read_occ(buf, pos, entry.end, depth)
        if f.number == 1:
            ok = ok and _accepts(key_mask, f.wt)
        elif f.number == 2:
            ok = ok and _accepts(value_mask, f.wt)
        else:
            ok = False
    return ok


# The occurrences of each field across `spans`, the occurrences of one
# message at level `depth`, in wire order: reading them in order is reading
# the concatenated message, which is protobuf's merge. Field `f` binds wire
# number `numbers[f][k]` when the occurrence's wire type is in `masks[f][k]`,
# and a map field (`key_masks[f]` nonzero) only its well-formed entries.
# Anything else is an unknown field, appended to `unknown` in wire order;
# `bad_entry` says which map field each malformed entry came from (else -1).
def _gather(
    buf: List[UInt8],
    spans: List[Occ],
    numbers: List[List[Int]],
    masks: List[List[Int]],
    key_masks: List[Int],
    value_masks: List[Int],
    depth: Int,
    mut fields: List[List[Occ]],
    mut unknown: List[Occ],
    mut bad_entry: List[Int],
) raises DeserializationError:
    fields.clear()
    for _ in range(len(numbers)):
        fields.append(List[Occ]())
    for s in spans:
        if s.wt != _LEN:
            raise _mismatch("expected a message, found a scalar")
        var pos = s.start
        while pos < s.end:
            var o = _read_occ(buf, pos, s.end, depth)
            var bound = False
            var entry_of = -1
            for f in range(len(numbers)):
                for k in range(len(numbers[f])):
                    if numbers[f][k] != o.number or not _accepts(
                        masks[f][k], o.wt
                    ):
                        continue
                    if key_masks[f] == 0 or _entry_ok(
                        buf, o, key_masks[f], value_masks[f], depth + 1
                    ):
                        fields[f].append(o)
                        bound = True
                    else:
                        entry_of = f
            if not bound:
                unknown.append(o)
                bad_entry.append(entry_of)


# The fields 1..n of one of this format's own positional messages (a tuple),
# any wire type: the element reads filter them by type.
def _positional(
    buf: List[UInt8], spans: List[Occ], n: Int, depth: Int
) raises DeserializationError -> List[List[Occ]]:
    var numbers = List[List[Int]]()
    var masks = List[List[Int]]()
    var none = List[Int]()
    for k in range(n):
        numbers.append([k + 1])
        masks.append([-1])
        none.append(0)
    var parts = List[List[Occ]]()
    var unknown = List[Occ]()
    var bad = List[Int]()
    _gather(buf, spans, numbers, masks, none, none, depth, parts, unknown, bad)
    return parts^


# A view of one value whose wire shape is `desc`, inside a message at level
# `depth`. In a field position (`field`) it holds every occurrence of the
# field, possibly none; otherwise exactly one, where a length-delimited one
# under a scalar read is a packed run read from `ppos` (and `used_packed`
# tells the seq how far it got). `store` is an `UnknownFields` field's bytes.
@fieldwise_init
struct ProtoDeserializer[origin: MutOrigin](Deserializer):
    var buf: Pointer[List[UInt8], Self.origin]
    var occs: List[Occ]
    var field: Bool
    var enc: Int
    var oneof: List[Int]
    var desc: Desc
    var depth: Int
    var ppos: Int
    var used_packed: Bool
    var store: Optional[List[UInt8]]

    comptime SeqType = ProtoSeqDe[Self.origin]
    comptime MapType = ProtoMapDe[Self.origin]
    comptime StructType = ProtoStructDe[Self.origin]
    comptime TupleType = ProtoTupleDe[Self.origin]
    comptime EnumType = ProtoEnumDe[Self.origin]

    @staticmethod
    def of_field(
        buf: Pointer[List[UInt8], Self.origin],
        var occs: List[Occ],
        enc: Int,
        var oneof: List[Int],
        var desc: Desc,
        depth: Int,
    ) -> Self:
        return Self(
            buf=buf,
            occs=occs^,
            field=True,
            enc=enc,
            oneof=oneof^,
            desc=desc^,
            depth=depth,
            ppos=-1,
            used_packed=False,
            store=None,
        )

    @staticmethod
    def of_element(
        buf: Pointer[List[UInt8], Self.origin],
        occ: Occ,
        enc: Int,
        var desc: Desc,
        depth: Int,
        ppos: Int,
    ) -> Self:
        return Self(
            buf=buf,
            occs=[occ],
            field=False,
            enc=enc,
            oneof=[],
            desc=desc^,
            depth=depth,
            ppos=ppos,
            used_packed=False,
            store=None,
        )

    def _scalar[
        DT: DType
    ](mut self, enc: Int) raises DeserializationError -> Scalar[DT]:
        if self.field:
            if not self.occs:
                return 0
            var o = self.occs[len(self.occs) - 1]
            return _from_raw[DT](_raw(self.buf[], o), o.wt, enc)
        var o = self.occs[0]
        if o.wt != _LEN:
            return _from_raw[DT](_raw(self.buf[], o), o.wt, enc)
        if self.ppos < 0:
            self.ppos = o.start
        if self.ppos >= o.end:
            raise _invalid("empty packed run")
        var wt = _packed_wire[DT](enc)
        var start = self.ppos
        if wt == _VARINT:
            _ = _varint(self.buf[], self.ppos, o.end)
        else:
            self.ppos += 4 if wt == _I32 else 8
            if self.ppos > o.end:
                raise _invalid("packed run ends mid-value")
        self.used_packed = True
        return _from_raw[DT](
            _raw(self.buf[], Occ(wt, start, self.ppos, o.number, start, 0)),
            wt,
            enc,
        )

    def _len_bytes(self) raises DeserializationError -> List[Byte]:
        var o: Occ
        if self.field:
            if not self.occs:
                return []
            o = self.occs[len(self.occs) - 1]
        else:
            o = self.occs[0]
        if o.wt != _LEN:
            raise _mismatch("expected a length-delimited value")
        return List[Byte](Span(self.buf[])[o.start : o.end])

    def _nested(self) raises DeserializationError -> Int:
        if self.depth + 1 > _MAX_DEPTH:
            raise _too_deep()
        return self.depth + 1

    # A box's content: field 1 (or a `Variant`'s arm k as field k + 1), of
    # the given wire types.
    def _unbox(
        self, var numbers: List[Int], var masks: List[Int]
    ) raises DeserializationError -> List[Occ]:
        var parts = List[List[Occ]]()
        var unknown = List[Occ]()
        var bad = List[Int]()
        _gather(
            self.buf[],
            self.occs,
            [numbers^],
            [masks^],
            [0],
            [0],
            self._nested(),
            parts,
            unknown,
            bad,
        )
        return parts[0].copy()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        return self._scalar[DType.uint64](_ENC_VARINT) != 0

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        return self._scalar[DT](self.enc)

    # Every occurrence is checked, not just the last one read: upb parses,
    # and so validates, each one it overwrites.
    def expect_string(mut self) raises DeserializationError -> String:
        if self.field:
            for o in self.occs:
                if o.wt != _LEN:
                    raise _mismatch("expected a length-delimited value")
                _ = _utf8(Span(self.buf[])[o.start : o.end])
        return _utf8(Span(self._len_bytes()))

    def expect_bytes(mut self) raises DeserializationError -> List[Byte]:
        if self.store:
            return self.store.value().copy()
        return self._len_bytes()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        if self.field:
            if not self.occs:
                return Optional[T]()
            return Optional[T](deserialize[T](self))
        var d = _desc_of[T](self.enc)
        var inner = self._unbox([1], [d.mask])
        if not inner:
            return Optional[T]()
        var sub = Self.of_field(
            self.buf, inner^, self.enc, [], d^, self._nested()
        )
        return Optional[T](deserialize[T](sub))

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        if self.field:
            return ProtoSeqDe[Self.origin].over(
                self.buf,
                self.occs.copy(),
                self.enc,
                self.desc.packed,
                self.depth,
            )
        var inner = self._unbox([1], [self.desc.mask])
        return ProtoSeqDe[Self.origin].over(
            self.buf, inner^, self.enc, self.desc.packed, self._nested()
        )

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        var entries: List[Occ]
        var depth: Int
        if self.field:
            entries = self.occs.copy()
            depth = self.depth
        else:
            entries = self._unbox([1], [_M_LEN])
            depth = self._nested()
        if depth + 1 > _MAX_DEPTH:
            raise _too_deep()
        var good = List[Occ]()
        for e in entries:
            if _entry_ok(
                self.buf[],
                e,
                self.desc.key_mask,
                self.desc.value_mask,
                depth + 1,
            ):
                good.append(e)
        return ProtoMapDe(
            buf=self.buf,
            entries=good^,
            next=0,
            enc=self.enc,
            depth=depth + 1,
            key_mask=self.desc.key_mask,
            value_mask=self.desc.value_mask,
            value=[],
        )

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        comptime assert _unique_numbers[T](), (
            "two fields share a protobuf field number, or one is outside"
            " 1..2^29-1"
        )
        comptime assert (
            _store_count[T]() <= 1
        ), "a message may hold at most one UnknownFields"
        var depth = self._nested()
        var numbers = List[List[Int]]()
        var masks = List[List[Int]]()
        var key_masks = List[Int]()
        var value_masks = List[Int]()
        var st = ProtoStructDe(
            buf=self.buf,
            fields=[],
            unknown=[],
            store=-1,
            yield_absent=[],
            encs=[],
            oneofs=[],
            descs=[],
            depth=depth,
            next=0,
            current=-1,
        )
        comptime for i in range(reflect[T].field_count()):
            comptime FT = reflect[T].field_types()[i]
            var enc = _encoding[T, i]()
            var d = _desc_of[FT](enc)
            var oneof = _oneof[T, i]()
            comptime if _is_store[T, i]():
                st.store = i
                masks.append([])
            else:
                if oneof:
                    if len(d.arms) != len(oneof):
                        raise _invalid(
                            "ProtoOneof must list one number per arm"
                        )
                    masks.append(d.arms.copy())
                else:
                    masks.append([d.mask])
            numbers.append(_numbers_of[T, i]())
            key_masks.append(d.key_mask)
            value_masks.append(d.value_mask)
            st.oneofs.append(oneof^)
            st.encs.append(enc)
            st.descs.append(d^)
            # The framework fills Optional/Skip/Default fields itself; every
            # other field absent from the wire reads as its zero value.
            st.yield_absent.append(not may_be_absent[T, i]())
        var unknown = List[Occ]()
        var bad_entry = List[Int]()
        _gather(
            self.buf[],
            self.occs,
            numbers,
            masks,
            key_masks,
            value_masks,
            depth,
            st.fields,
            unknown,
            bad_entry,
        )
        comptime if count_struct_annotations[T, DenyUnknownFields]() > 0:
            if unknown:
                raise DeserializationError(
                    String("Unknown field number"), DerErrorKind.UnknownField
                )
        var pieces = List[List[UInt8]]()
        for o in unknown:
            pieces.append(
                List[UInt8](Span(self.buf[])[o.raw_start : o.raw_end])
            )
        comptime for i in range(reflect[T].field_count()):
            comptime FT = reflect[T].field_types()[i]
            comptime if conforms_to(FT, ProtoMap):
                for k in range(len(unknown)):
                    if bad_entry[k] == i:
                        pieces[k] = downcast[FT, ProtoMap].reencode_entry(
                            self.buf, unknown[k], st.encs[i], depth + 1
                        )
        for p in pieces:
            st.unknown.extend(Span(p))
        return st^

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        var depth = self._nested()
        return ProtoTupleDe(
            buf=self.buf,
            parts=_positional(self.buf[], self.occs, field_count, depth),
            next=0,
            depth=depth,
        )

    # The last member seen wins, and switching members clears the old one:
    # the payload is the trailing run of that member's occurrences.
    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        var numbers: List[Int]
        var cands: List[Occ]
        var depth: Int
        if self.field and self.oneof:
            numbers = self.oneof.copy()
            cands = self.occs.copy()
            depth = self.depth
        else:
            comptime arms = len(arm_names)
            numbers = List[Int]()
            for k in range(arms):
                numbers.append(k + 1)
            cands = self._unbox(
                numbers.copy(), _desc_of[T](self.enc).arms.copy()
            )
            depth = self._nested()
        if not cands:
            raise _absent()
        var last = cands[len(cands) - 1].number
        var first = len(cands) - 1
        while first > 0 and cands[first - 1].number == last:
            first -= 1
        comptime assert conforms_to(
            T, ProtoOneofArms
        ), "begin_enum is only reached for a Variant"
        var at = 0
        while at < first:
            var end = at
            var run = List[Occ]()
            while end < first and cands[end].number == cands[at].number:
                run.append(cands[end])
                end += 1
            for k in range(len(numbers)):
                if numbers[k] == cands[at].number:
                    downcast[T, ProtoOneofArms].check_arm(
                        k, self.buf, run^, self.enc, depth
                    )
                    break
            at = end
        var payload = List[Occ]()
        for k in range(first, len(cands)):
            payload.append(cands[k])
        var arm = -1
        for k in range(len(numbers)):
            if numbers[k] == last:
                arm = k
        return ProtoEnumDe(
            buf=self.buf, idx=arm, payload=payload^, enc=self.enc, depth=depth
        )


@fieldwise_init
struct ProtoStructDe[origin: MutOrigin](StructDerState):
    var buf: Pointer[List[UInt8], Self.origin]
    var fields: List[List[Occ]]
    var unknown: List[UInt8]
    # The `UnknownFields` field's index, -1 if the struct has none.
    var store: Int
    var yield_absent: List[Bool]
    var encs: List[Int]
    var oneofs: List[List[Int]]
    var descs: List[Desc]
    var depth: Int
    var next: Int
    var current: Int

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        while self.next < len(self.fields):
            var i = self.next
            self.next += 1
            if self.fields[i] or self.yield_absent[i]:
                self.current = i
                return i
        return None

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var i = self.current
        var sub = ProtoDeserializer[Self.origin].of_field(
            self.buf,
            self.fields[i].copy(),
            self.encs[i],
            self.oneofs[i].copy(),
            self.descs[i].copy(),
            self.depth,
        )
        if i == self.store:
            sub.store = self.unknown.copy()
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        pass

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct ProtoSeqDe[origin: MutOrigin](SeqDerState):
    var buf: Pointer[List[UInt8], Self.origin]
    var occs: List[Occ]
    var i: Int
    var ppos: Int
    var enc: Int
    # A seq of scalars: a length-delimited occurrence is a packed run, and
    # an empty one holds no element.
    var packed: Bool
    var depth: Int

    @staticmethod
    def over(
        buf: Pointer[List[UInt8], Self.origin],
        var occs: List[Occ],
        enc: Int,
        packed: Bool,
        depth: Int,
    ) -> Self:
        return Self(
            buf=buf,
            occs=occs^,
            i=0,
            ppos=-1,
            enc=enc,
            packed=packed,
            depth=depth,
        )

    def has_next(mut self) raises DeserializationError -> Bool:
        while self.i < len(self.occs):
            var o = self.occs[self.i]
            if not (self.packed and o.wt == _LEN):
                return True
            if self.ppos < 0:
                self.ppos = o.start
            if self.ppos < o.end:
                return True
            self.ppos = -1
            self.i += 1
        return False

    def expect_element[
        T: AnyType
    ](mut self, out result: T) raises DeserializationError:
        var o = self.occs[self.i]
        var sub = ProtoDeserializer[Self.origin].of_element(
            self.buf,
            o,
            self.enc,
            _desc_of[T](self.enc),
            self.depth,
            self.ppos,
        )
        result = deserialize[T](sub)
        if sub.used_packed and sub.ppos < o.end:
            self.ppos = sub.ppos
        else:
            self.ppos = -1
            self.i += 1

    def end(mut self) raises DeserializationError:
        pass


# Entries are `{1: key, 2: value}` messages at level `depth`; `value` holds
# the current entry's value occurrences between `expect_key` and
# `expect_value`.
@fieldwise_init
struct ProtoMapDe[origin: MutOrigin](MapDerState):
    var buf: Pointer[List[UInt8], Self.origin]
    var entries: List[Occ]
    var next: Int
    var enc: Int
    var depth: Int
    var key_mask: Int
    var value_mask: Int
    var value: List[Occ]

    def has_next(mut self) raises DeserializationError -> Bool:
        return self.next < len(self.entries)

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        var parts = List[List[Occ]]()
        var unknown = List[Occ]()
        var bad = List[Int]()
        _gather(
            self.buf[],
            [self.entries[self.next]],
            [[1], [2]],
            [[self.key_mask], [self.value_mask]],
            [0, 0],
            [0, 0],
            self.depth,
            parts,
            unknown,
            bad,
        )
        self.next += 1
        self.value = parts[1].copy()
        var sub = ProtoDeserializer[Self.origin].of_field(
            self.buf,
            parts[0].copy(),
            self.enc,
            [],
            _desc_of[T](self.enc),
            self.depth,
        )
        return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = ProtoDeserializer[Self.origin].of_field(
            self.buf,
            self.value.copy(),
            self.enc,
            [],
            _desc_of[T](self.enc),
            self.depth,
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct ProtoTupleDe[origin: MutOrigin](TupleDerState):
    var buf: Pointer[List[UInt8], Self.origin]
    var parts: List[List[Occ]]
    var next: Int
    var depth: Int

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var d = _desc_of[T](_ENC_VARINT)
        var occs = _filter(self.parts[self.next], d.mask)
        self.next += 1
        var sub = ProtoDeserializer[Self.origin].of_field(
            self.buf, occs^, _ENC_VARINT, [], d^, self.depth
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct ProtoEnumDe[origin: MutOrigin](EnumDerState):
    var buf: Pointer[List[UInt8], Self.origin]
    var idx: Int
    var payload: List[Occ]
    var enc: Int
    var depth: Int

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = ProtoDeserializer[Self.origin].of_field(
            self.buf,
            self.payload.copy(),
            self.enc,
            [],
            _desc_of[T](self.enc),
            self.depth,
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


def from_proto[
    T: Deinitable
](var bytes: List[UInt8], out result: T) raises DeserializationError:
    var end = len(bytes)
    var d = ProtoDeserializer.of_element(
        Pointer(to=bytes),
        Occ(_LEN, 0, end, 0, 0, end),
        _ENC_VARINT,
        _desc_of[T](_ENC_VARINT),
        -1,
        -1,
    )
    result = deserialize[T](d)
    if d.used_packed and d.ppos != end:
        raise _invalid("trailing bytes after the value")


# Hand-written wire literals for the tests, as hex pairs: `wire("08 96 01")`.
# A list literal would be reflowed to one byte per line by `mojo format`.
def wire(hex: StringSlice) raises -> List[UInt8]:
    var out = List[UInt8]()
    for word in hex.split():
        out.append(UInt8(atol(word, base=16)))
    return out^
