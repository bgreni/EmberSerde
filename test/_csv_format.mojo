from emberserde.serialize import (
    Serializer,
    SeqSerState,
    StructSerState,
    TupleSerState,
    serialize,
)
from emberserde.deserialize import (
    Deserializer,
    SeqDerState,
    StructDerState,
    TupleDerState,
    checked_scalar,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    SerErrorKind,
    DeserializationError,
    DerErrorKind,
)
from emberserde.field_meta import field_index, next_wire_field, wire_field_names
from emberserde.unsupported import Unsupported
from emberserde.utils import Base

# What a (de)serializer is positioned at. CSV is fixed two-level nesting, so
# each level accepts exactly one shape and rejects the rest at runtime.
comptime _DOC = 0
comptime _ROW = 1
comptime _CELL = 2


def _shape_message(level: Int) -> String:
    if level == _DOC:
        return "CSV input must be a sequence of rows"
    if level == _ROW:
        return "a CSV row must be a struct or a tuple"
    return "a CSV cell cannot hold a nested container"


def _ser_shape_error(level: Int) -> SerializationError:
    return SerializationError(_shape_message(level), SerErrorKind.InvalidValue)


def _der_shape_error(level: Int) -> DeserializationError:
    return DeserializationError(
        _shape_message(level), DerErrorKind.TypeMismatch
    )


def _invalid(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.InvalidValue)


# Quotes an empty string too, so `Some("")` (`""`) stays distinct from `None`
# (an empty cell) on the wire.
def _write_cell(mut out: String, v: StringSlice):
    if not (
        v.byte_length() == 0 or "," in v or '"' in v or "\n" in v or "\r" in v
    ):
        out += v
        return
    out += '"'
    out += v.replace('"', '""')
    out += '"'


@fieldwise_init
struct CsvSeqSer[origin: MutOrigin, has_headers: Bool](SeqSerState):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = CsvSerializer[Self.origin, Self.has_headers](
            out=self.out, level=_ROW, header=self.first
        )
        self.first = False
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


@fieldwise_init
struct CsvRowSer[origin: MutOrigin, has_headers: Bool](
    StructSerState, TupleSerState
):
    var out: Pointer[String, Self.origin]
    var first: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        if not self.first:
            self.out[] += ","
        self.first = False
        var sub = CsvSerializer[Self.origin, Self.has_headers](
            out=self.out, level=_CELL, header=False
        )
        serialize(v, sub)

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        self.serialize_element(v)

    def end(mut self) raises SerializationError:
        self.out[] += "\n"


@fieldwise_init
struct CsvSerializer[origin: MutOrigin, has_headers: Bool = True](Serializer):
    var out: Pointer[String, Self.origin]
    var level: Int
    # Set on the first row only: its `begin_struct` writes the header.
    var header: Bool

    comptime SeqType = CsvSeqSer[Self.origin, Self.has_headers]
    comptime StructType = CsvRowSer[Self.origin, Self.has_headers]
    comptime TupleType = CsvRowSer[Self.origin, Self.has_headers]
    comptime MapType = Unsupported["maps"]
    comptime EnumType = Unsupported["enums"]

    def _expect_cell(self) raises SerializationError:
        if self.level != _CELL:
            raise _ser_shape_error(self.level)

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self._expect_cell()
        self.out[] += "true" if v else "false"

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self._expect_cell()
        self.out[] += String(v)

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self._expect_cell()
        _write_cell(self.out[], v)

    def serialize_none(mut self) raises SerializationError:
        self._expect_cell()

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        if self.level != _DOC:
            raise _ser_shape_error(self.level)
        return CsvSeqSer[Self.origin, Self.has_headers](
            out=self.out, first=True
        )

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        return Self.MapType()

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        if self.level != _ROW:
            raise _ser_shape_error(self.level)
        comptime if Self.has_headers:
            if self.header:
                var names = wire_field_names[T]()
                for i in range(len(names)):
                    if i != 0:
                        self.out[] += ","
                    _write_cell(self.out[], names[i])
                self.out[] += "\n"
        return CsvRowSer[Self.origin, Self.has_headers](
            out=self.out, first=True
        )

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        comptime assert not Self.has_headers, (
            "a tuple has no column names to write a CSV header from;"
            " serialize tuple rows with has_headers=False"
        )
        if self.level != _ROW:
            raise _ser_shape_error(self.level)
        return CsvRowSer[Self.origin, Self.has_headers](
            out=self.out, first=True
        )

    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        return Self.EnumType()


def to_csv[
    T: AnyType, //, has_headers: Bool = True
](value: T) raises SerializationError -> String:
    var buf = String()
    var s = CsvSerializer[origin_of(buf), has_headers](
        out=Pointer(to=buf), level=_DOC, header=False
    )
    serialize(value, s)
    return buf^


@fieldwise_init
struct CsvCursor(Movable):
    var buf: String
    var pos: Int
    var header: List[String]

    def at_end(self) -> Bool:
        return self.pos >= self.buf.byte_length()

    def peek(self) -> Int:
        if self.at_end():
            return -1
        return Int(self.buf.as_bytes()[self.pos])

    def at_line_end(self) -> Bool:
        var c = self.peek()
        return c == -1 or c == ord("\n") or c == ord("\r")

    def at_cell_end(self) -> Bool:
        return self.at_line_end() or self.peek() == ord(",")

    def end_line(mut self):
        if self.peek() == ord("\r"):
            self.pos += 1
        if self.peek() == ord("\n"):
            self.pos += 1

    def _slice(self, start: Int, end: Int) -> String:
        return String(
            StringSlice(unsafe_from_utf8=self.buf.as_bytes()[start:end])
        )

    # Leaves the cursor on the cell's terminator (`,`, a line end, or EOF).
    def read_cell(mut self) raises DeserializationError -> String:
        var start = self.pos
        if self.peek() != ord('"'):
            while not self.at_cell_end():
                self.pos += 1
            return self._slice(start, self.pos)
        self.pos += 1
        var result = String()
        var run_start = self.pos
        while True:
            if self.at_end():
                raise _invalid("unterminated quoted cell")
            if self.peek() != ord('"'):
                self.pos += 1
                continue
            result += self._slice(run_start, self.pos)
            self.pos += 1
            if self.peek() != ord('"'):
                break
            # A doubled quote: the second one opens the next run, so it is
            # kept as a literal `"`.
            run_start = self.pos
            self.pos += 1
        if not self.at_cell_end():
            raise _invalid("unexpected character after a closing quote")
        return result^

    def read_header(mut self) raises DeserializationError:
        if self.at_end():
            return
        while True:
            self.header.append(self.read_cell())
            if self.at_line_end():
                break
            self.pos += 1
        self.end_line()


@fieldwise_init
struct CsvSeqDe[origin: MutOrigin, has_headers: Bool](SeqDerState):
    var cursor: Pointer[CsvCursor, Self.origin]

    def has_next(mut self) raises DeserializationError -> Bool:
        return not self.cursor[].at_end()

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = CsvDeserializer[Self.origin, Self.has_headers](
            cursor=self.cursor, level=_ROW
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


@fieldwise_init
struct CsvRowDe[origin: MutOrigin, has_headers: Bool](
    StructDerState, TupleDerState
):
    var cursor: Pointer[CsvCursor, Self.origin]
    # Cells consumed so far in this row.
    var col: Int
    # Headerless struct rows only: the declaration index to resume
    # `next_wire_field` from, which runs ahead of `col` past `Skip` fields.
    var next: Int

    # Steps onto the next cell, or returns False at the end of the row.
    def _next_cell(mut self) -> Bool:
        if self.col > 0:
            if self.cursor[].at_line_end():
                return False
            self.cursor[].pos += 1
        self.col += 1
        return True

    # A short row just ends early: the framework fills or rejects the
    # columns it never reached.
    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        if not self._next_cell():
            return None
        comptime if Self.has_headers:
            if self.col > len(self.cursor[].header):
                raise _invalid("row has too many cells")
            return field_index[T](self.cursor[].header[self.col - 1])
        else:
            var field = next_wire_field[T](self.next)
            if not field:
                raise _invalid("row has too many cells")
            self.next = field.value() + 1
            return field

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = CsvDeserializer[Self.origin, Self.has_headers](
            cursor=self.cursor, level=_CELL
        )
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        _ = self.cursor[].read_cell()

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        if not self._next_cell():
            raise _invalid("row has too few cells")
        return self.expect_field_value[T]()

    def end(mut self) raises DeserializationError:
        if not self.cursor[].at_line_end():
            raise _invalid("row has too many cells")
        self.cursor[].end_line()


@fieldwise_init
struct CsvDeserializer[origin: MutOrigin, has_headers: Bool = True](
    Deserializer
):
    var cursor: Pointer[CsvCursor, Self.origin]
    var level: Int

    comptime SeqType = CsvSeqDe[Self.origin, Self.has_headers]
    comptime StructType = CsvRowDe[Self.origin, Self.has_headers]
    comptime TupleType = CsvRowDe[Self.origin, Self.has_headers]
    comptime MapType = Unsupported["maps"]
    comptime EnumType = Unsupported["enums"]

    def _cell(mut self) raises DeserializationError -> String:
        if self.level != _CELL:
            raise _der_shape_error(self.level)
        return self.cursor[].read_cell()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        var cell = self._cell()
        if cell == "true":
            return True
        if cell == "false":
            return False
        raise DeserializationError(
            String(t"expected a boolean: '{cell}'"), DerErrorKind.TypeMismatch
        )

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        return checked_scalar[DT](self._cell())

    def expect_string(mut self) raises DeserializationError -> String:
        return self._cell()

    # Only an unquoted empty cell is `None`; `""` is a present empty string.
    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        if self.level == _CELL and self.cursor[].at_cell_end():
            return Optional[T]()
        return Optional[T](deserialize[T](self))

    # A header is consumed even for tuple rows, which ignore its names.
    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        if self.level != _DOC:
            raise _der_shape_error(self.level)
        comptime if Self.has_headers:
            self.cursor[].read_header()
        return CsvSeqDe[Self.origin, Self.has_headers](cursor=self.cursor)

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        return Self.MapType()

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        if self.level != _ROW:
            raise _der_shape_error(self.level)
        return CsvRowDe[Self.origin, Self.has_headers](
            cursor=self.cursor, col=0, next=0
        )

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        if self.level != _ROW:
            raise _der_shape_error(self.level)
        return CsvRowDe[Self.origin, Self.has_headers](
            cursor=self.cursor, col=0, next=0
        )

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        return Self.EnumType()


def from_csv[
    T: Deinitable, has_headers: Bool = True
](var s: String, out result: T) raises DeserializationError:
    var cursor = CsvCursor(s^, 0, [])
    var d = CsvDeserializer[origin_of(cursor), has_headers](
        cursor=Pointer(to=cursor), level=_DOC
    )
    result = deserialize[T](d)
