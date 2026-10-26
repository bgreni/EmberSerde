# A non-shipping, test-only TOML subset whose point is `TomlDatetime`. TOML
# has native datetime literals, and the format recognizes the type at
# compile time to write and read them bare; every other format gets the
# type's own impls, an RFC 3339 string. toml-rs instead routes its datetime
# through a magic struct name, which leaks into other formats as
# `{"$__toml_private_datetime": "..."}`.
#
# The subset: a document is one flat table of `key = value` lines, and a
# value is a basic string, a decimal integer or float, a boolean or a
# datetime. Tables, arrays, inline tables, literal and multi-line strings,
# dotted keys and `Optional` raise "unsupported in this TOML subset".

from std.builtin.rebind import rebind_var
from emberserde.serialize import (
    Serializable,
    Serializer,
    StructSerState,
    serialize,
)
from emberserde.deserialize import (
    Deserializable,
    Deserializer,
    StructDerState,
    checked_scalar,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    SerErrorKind,
    DeserializationError,
    DerErrorKind,
)
from emberserde.field_meta import field_index
from emberserde.unsupported import Unsupported
from emberserde.utils import Base
from _text_utils import TextCursor, is_digit, write_quoted

comptime _DOC = 0
comptime _VALUE = 1

comptime _STRING = 0
comptime _BOOL = 1
comptime _NUMBER = 2
comptime _DATETIME = 3


def _kind_name(kind: Int) -> String:
    if kind == _STRING:
        return "string"
    if kind == _BOOL:
        return "boolean"
    if kind == _NUMBER:
        return "number"
    return "datetime"


def _invalid(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.InvalidValue)


def _mismatch(expected: Int, found: Int) -> DeserializationError:
    return DeserializationError(
        String("expected a ")
        + _kind_name(expected)
        + ", found a "
        + _kind_name(found),
        DerErrorKind.TypeMismatch,
    )


def _unsupported(what: StaticString) -> DeserializationError:
    return _invalid(String("unsupported in this TOML subset: ") + what)


def _ser_unsupported(what: StaticString) -> SerializationError:
    return SerializationError(
        String("unsupported in this TOML subset: ") + what,
        SerErrorKind.InvalidValue,
    )


def _bad_datetime(text: StringSlice) -> DeserializationError:
    return _invalid(String("invalid datetime: '") + text + "'")


def _is_bare_char(c: Int) -> Bool:
    return (
        is_digit(c)
        or (c >= ord("a") and c <= ord("z"))
        or (c >= ord("A") and c <= ord("Z"))
        or c == ord("_")
        or c == ord("-")
    )


def _byte(b: Span[Byte, _], i: Int) -> Int:
    return Int(b[i]) if i < len(b) else -1


# `count` digits at `i` as a number, or -1 when any is missing.
def _digits(b: Span[Byte, _], i: Int, count: Int) -> Int:
    var v = 0
    for k in range(count):
        var c = _byte(b, i + k)
        if not is_digit(c):
            return -1
        v = v * 10 + c - ord("0")
    return v


def _days_in_month(year: Int, month: Int) -> Int:
    if month == 2:
        var leap = year % 4 == 0 and (year % 100 != 0 or year % 400 == 0)
        return 29 if leap else 28
    if month == 4 or month == 6 or month == 9 or month == 11:
        return 30
    return 31


def _pad(mut writer: Some[Writer], v: Int, width: Int):
    var s = String(v)
    for _ in range(width - s.byte_length()):
        writer.write("0")
    writer.write(s)


# Any of TOML's four datetime kinds: offset date-time, local date-time, local
# date (`has_time` False) and local time (`has_date` False).
# `offset_minutes` is minutes east of UTC, `None` for the local kinds.
@fieldwise_init
struct TomlDatetime(
    Copyable, Defaultable, Deserializable, Movable, Serializable, Writable
):
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var nanosecond: Int
    var has_date: Bool
    var has_time: Bool
    var offset_minutes: Optional[Int]

    # The Unix epoch, so a default is still a valid datetime.
    def __init__(out self):
        self = Self(1970, 1, 1, 0, 0, 0, 0, True, True, Optional[Int](0))

    @staticmethod
    def parse(text: StringSlice) raises DeserializationError -> Self:
        var b = text.as_bytes()
        var r = Self(0, 0, 0, 0, 0, 0, 0, False, False, None)
        var i = 0
        if _byte(b, 4) == ord("-"):
            r.year = _digits(b, 0, 4)
            r.month = _digits(b, 5, 2)
            r.day = _digits(b, 8, 2)
            if (
                r.year < 0
                or _byte(b, 7) != ord("-")
                or r.month < 1
                or r.month > 12
                or r.day < 1
                or r.day > _days_in_month(r.year, r.month)
            ):
                raise _bad_datetime(text)
            r.has_date = True
            i = 10
            if i == len(b):
                return r^
            var sep = _byte(b, i)
            if sep != ord("T") and sep != ord("t") and sep != ord(" "):
                raise _bad_datetime(text)
            i += 1
        r.hour = _digits(b, i, 2)
        r.minute = _digits(b, i + 3, 2)
        r.second = _digits(b, i + 6, 2)
        # RFC 3339 allows a leap second.
        if (
            _byte(b, i + 2) != ord(":")
            or _byte(b, i + 5) != ord(":")
            or r.hour < 0
            or r.hour > 23
            or r.minute < 0
            or r.minute > 59
            or r.second < 0
            or r.second > 60
        ):
            raise _bad_datetime(text)
        r.has_time = True
        i += 8
        if _byte(b, i) == ord("."):
            i += 1
            var start = i
            while is_digit(_byte(b, i)):
                # TOML truncates precision it can't hold, never rounds.
                if i - start < 9:
                    r.nanosecond = r.nanosecond * 10 + _byte(b, i) - ord("0")
                i += 1
            if i == start:
                raise _bad_datetime(text)
            for _ in range(9 - min(i - start, 9)):
                r.nanosecond *= 10
        if i < len(b):
            var c = _byte(b, i)
            if not r.has_date:
                raise _bad_datetime(text)
            if c == ord("Z") or c == ord("z"):
                r.offset_minutes = 0
                i += 1
            elif c == ord("+") or c == ord("-"):
                var oh = _digits(b, i + 1, 2)
                var om = _digits(b, i + 4, 2)
                if (
                    _byte(b, i + 3) != ord(":")
                    or oh < 0
                    or oh > 23
                    or om < 0
                    or om > 59
                ):
                    raise _bad_datetime(text)
                var off = oh * 60 + om
                r.offset_minutes = -off if c == ord("-") else off
                i += 6
            else:
                raise _bad_datetime(text)
        if i != len(b):
            raise _bad_datetime(text)
        return r^

    def write_to(self, mut writer: Some[Writer]):
        if self.has_date:
            _pad(writer, self.year, 4)
            writer.write("-")
            _pad(writer, self.month, 2)
            writer.write("-")
            _pad(writer, self.day, 2)
            if self.has_time:
                writer.write("T")
        if not self.has_time:
            return
        _pad(writer, self.hour, 2)
        writer.write(":")
        _pad(writer, self.minute, 2)
        writer.write(":")
        _pad(writer, self.second, 2)
        if self.nanosecond > 0:
            var frac = self.nanosecond
            var width = 9
            while frac % 10 == 0:
                frac //= 10
                width -= 1
            writer.write(".")
            _pad(writer, frac, width)
        if self.offset_minutes:
            var off = self.offset_minutes.value()
            if off == 0:
                writer.write("Z")
            else:
                writer.write("-" if off < 0 else "+")
                _pad(writer, abs(off) // 60, 2)
                writer.write(":")
                _pad(writer, abs(off) % 60, 2)

    # The TOML format calls these in place of `serialize`/`deserialize`.
    def serialize_toml(
        self, mut s: TomlSerializer[_]
    ) raises SerializationError:
        s.out[].write(self)

    @staticmethod
    def deserialize_toml(
        mut d: TomlDeserializer[_],
    ) raises DeserializationError -> Self:
        d._expect(_DATETIME)
        return Self.parse(_read_datetime_text(d.cursor[]))

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(String(self))

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self.parse(d.expect_string())


def _write_key(mut out: String, key: StringSlice):
    var b = key.as_bytes()
    var bare = len(b) > 0
    for i in range(len(b)):
        if not _is_bare_char(Int(b[i])):
            bare = False
    if bare:
        out += key
    else:
        write_quoted(out, key)


@fieldwise_init
struct TomlTableSer[origin: MutOrigin](StructSerState):
    var out: Pointer[String, Self.origin]

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        _write_key(self.out[], field_name)
        self.out[] += " = "
        var sub = TomlSerializer[Self.origin](out=self.out, level=_VALUE)
        comptime if type_of(v) == TomlDatetime:
            rebind[TomlDatetime](v).serialize_toml(sub)
        else:
            serialize(v, sub)
        self.out[] += "\n"

    def end(mut self) raises SerializationError:
        pass


@fieldwise_init
struct TomlSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]
    var level: Int

    comptime StructType = TomlTableSer[Self.origin]
    comptime SeqType = Unsupported["arrays"]
    comptime MapType = Unsupported["maps"]
    comptime TupleType = Unsupported["tuples"]
    comptime EnumType = Unsupported["enums"]

    def _expect_value(self) raises SerializationError:
        if self.level != _VALUE:
            raise SerializationError(
                String("a TOML document must be a table"),
                SerErrorKind.InvalidValue,
            )

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self._expect_value()
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self._expect_value()
        comptime if dt == DType.uint64:
            if rebind[UInt64](v) > UInt64(Int64.MAX):
                raise SerializationError(
                    String("TOML integers are signed 64-bit"),
                    SerErrorKind.InvalidValue,
                )
        self.out[] += String(v)

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self._expect_value()
        write_quoted(self.out[], v)

    def serialize_none(mut self) raises SerializationError:
        raise _ser_unsupported("Optional")

    def serialize_some(mut self, v: Some[AnyType]) raises SerializationError:
        raise _ser_unsupported("Optional")

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        return Self.SeqType()

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        return Self.MapType()

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        if self.level != _DOC:
            raise _ser_unsupported("nested tables")
        return TomlTableSer[Self.origin](out=self.out)

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        return Self.TupleType()

    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        return Self.EnumType()


def to_toml[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = TomlSerializer[origin_of(buf)](out=Pointer(to=buf), level=_DOC)
    serialize(value, s)
    return buf^


def _skip_spaces(mut c: TextCursor):
    while c.peek() == ord(" ") or c.peek() == ord("\t"):
        c.advance()


def _skip_comment(mut c: TextCursor):
    if c.peek() != ord("#"):
        return
    while c.peek() != -1 and c.peek() != ord("\n") and c.peek() != ord("\r"):
        c.advance()


def _take_newline(mut c: TextCursor) -> Bool:
    for nl in ["\n", "\r\n"]:
        if c.starts_with(nl):
            c.pos += nl.byte_length()
            return True
    return False


def _end_line(mut c: TextCursor) raises DeserializationError:
    _skip_spaces(c)
    _skip_comment(c)
    if not _take_newline(c) and not c.at_end():
        raise _invalid("expected a newline after a value")


# Steps over blank and comment lines; False at the end of the input.
def _next_key(mut c: TextCursor) raises DeserializationError -> Bool:
    while True:
        _skip_spaces(c)
        _skip_comment(c)
        if _take_newline(c):
            continue
        if c.at_end():
            return False
        if c.peek() == ord("["):
            raise _unsupported("tables")
        return True


def _read_key(mut c: TextCursor) raises DeserializationError -> String:
    var key: String
    if c.peek() == ord('"'):
        key = c.read_quoted[toml=True]()
    elif c.peek() == ord("'"):
        raise _unsupported("literal strings")
    else:
        var start = c.pos
        while _is_bare_char(c.peek()):
            c.advance()
        if c.pos == start:
            raise _invalid("expected a key")
        key = c.slice(start, c.pos)
    _skip_spaces(c)
    if c.peek() == ord("."):
        raise _unsupported("dotted keys")
    if c.peek() != ord("="):
        raise _invalid("expected '=' after a key")
    c.advance()
    _skip_spaces(c)
    return key^


def _digit_run(c: TextCursor, n: Int) -> Bool:
    for k in range(n):
        if not is_digit(c.peek(k)):
            return False
    return True


def _value_kind(c: TextCursor) raises DeserializationError -> Int:
    var b = c.peek()
    if b == ord('"'):
        if c.starts_with('"""'):
            raise _unsupported("multi-line strings")
        return _STRING
    if b == ord("'"):
        raise _unsupported("literal strings")
    if b == ord("["):
        raise _unsupported("arrays")
    if b == ord("{"):
        raise _unsupported("inline tables")
    if b == ord("t") or b == ord("f"):
        return _BOOL
    # A date starts `YYYY-`, a time `HH:`.
    if (_digit_run(c, 4) and c.peek(4) == ord("-")) or (
        _digit_run(c, 2) and c.peek(2) == ord(":")
    ):
        return _DATETIME
    if b == -1 or b == ord("#") or b == ord("\n") or b == ord("\r"):
        raise _invalid("expected a value")
    return _NUMBER


def _read_bare(mut c: TextCursor) -> String:
    var start = c.pos
    while True:
        var b = c.peek()
        if (
            b == -1
            or b == ord(" ")
            or b == ord("\t")
            or b == ord("#")
            or b == ord("\n")
            or b == ord("\r")
        ):
            break
        c.advance()
    return c.slice(start, c.pos)


def _read_datetime_text(mut c: TextCursor) -> String:
    var text = _read_bare(c)
    # A space may stand in for the `T`; followed by `HH:` it is that
    # separator, not the end of a local date.
    if (
        text.byte_length() == 10
        and c.peek() == ord(" ")
        and is_digit(c.peek(1))
        and is_digit(c.peek(2))
        and c.peek(3) == ord(":")
    ):
        c.advance()
        text += " "
        text += _read_bare(c)
    return text^


@fieldwise_init
struct TomlTableDe[origin: MutOrigin](StructDerState):
    var cursor: Pointer[TextCursor, Self.origin]
    # `expect_field_value` returns the value itself, so the rest of its line
    # is checked when the next key is asked for.
    var after_value: Bool

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        if self.after_value:
            _end_line(self.cursor[])
            self.after_value = False
        if not _next_key(self.cursor[]):
            return None
        return field_index[T](_read_key(self.cursor[]))

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        self.after_value = True
        var sub = TomlDeserializer[Self.origin](
            cursor=self.cursor, level=_VALUE
        )
        comptime if T == TomlDatetime:
            comptime assert conforms_to(T, Movable)
            return rebind_var[T](TomlDatetime.deserialize_toml(sub))
        else:
            return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        self.after_value = True
        var kind = _value_kind(self.cursor[])
        if kind == _STRING:
            _ = self.cursor[].read_quoted[toml=True]()
        elif kind == _DATETIME:
            _ = _read_datetime_text(self.cursor[])
        else:
            _ = _read_bare(self.cursor[])

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct TomlDeserializer[origin: MutOrigin](Deserializer):
    var cursor: Pointer[TextCursor, Self.origin]
    var level: Int

    comptime StructType = TomlTableDe[Self.origin]
    comptime SeqType = Unsupported["arrays"]
    comptime MapType = Unsupported["maps"]
    comptime TupleType = Unsupported["tuples"]
    comptime EnumType = Unsupported["enums"]

    def _expect(mut self, expected: Int) raises DeserializationError:
        if self.level != _VALUE:
            raise DeserializationError(
                String("a TOML document must be a table"),
                DerErrorKind.TypeMismatch,
            )
        var kind = _value_kind(self.cursor[])
        if kind != expected:
            raise _mismatch(expected, kind)

    def expect_bool(mut self) raises DeserializationError -> Bool:
        self._expect(_BOOL)
        var tok = _read_bare(self.cursor[])
        if tok == "true":
            return True
        if tok == "false":
            return False
        raise _invalid(String("invalid boolean: '") + tok + "'")

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        self._expect(_NUMBER)
        return checked_scalar[DT](_read_bare(self.cursor[]))

    def expect_string(mut self) raises DeserializationError -> String:
        self._expect(_STRING)
        return self.cursor[].read_quoted[toml=True]()

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        raise _unsupported("Optional")

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        return Self.SeqType()

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        return Self.MapType()

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        if self.level != _DOC:
            raise _unsupported("nested tables")
        return TomlTableDe[Self.origin](cursor=self.cursor, after_value=False)

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        return Self.TupleType()

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        return Self.EnumType()


def from_toml[
    T: Deinitable
](var s: String, out result: T) raises DeserializationError:
    var cursor = TextCursor(s^, 0)
    var d = TomlDeserializer[origin_of(cursor)](
        cursor=Pointer(to=cursor), level=_DOC
    )
    result = deserialize[T](d)
