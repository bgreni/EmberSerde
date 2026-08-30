from std.testing import (
    assert_equal,
    assert_true,
    assert_false,
    assert_raises,
    TestSuite,
)

from emberserde.deserialize import (
    BorrowingDeserializer,
    Deserializable,
    Deserializer,
    RawKind,
    deserialize,
)
from emberserde.error import DeserializationError, DerErrorKind

from _json_format import JsonCursor, JsonDeserializer
from _token_format import TokenDeserializer


# Not representable as a test: re-tying the erased origin restores borrow
# checking, so outliving the input is a *compile* error. Verified by hand —
# giving `LazyRaw` a tracked `origin_of(cursor)` and then consuming `cursor`
# fails with "use of uninitialized value 'cursor'".
#
# The `Lazy` analogue: holds the raw wire bytes of one value, borrowed from
# the input, and defers any interpretation to `get`. `kind` selects which
# token shape the format must validate before handing the span over — the
# whole point of keying `raw_bytes` on a kind rather than always skipping a
# generic value.
@fieldwise_init
struct LazyRaw[o: ImmOrigin, kind: RawKind](Deserializable, Movable):
    var _data: Span[Byte, Self.o]

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        comptime assert conforms_to(
            type_of(d), BorrowingDeserializer
        ), "LazyRaw requires a borrowing deserializer"
        return Self(rebind[Span[Byte, Self.o]](d.raw_bytes[Self.kind]()))

    def as_slice(self) -> StringSlice[Self.o]:
        return StringSlice(unsafe_from_utf8=self._data)

    def byte_length(self) -> Int:
        return len(self._data)

    def address(self) -> Int:
        return Int(self._data.unsafe_ptr())


def _borrow[
    kind: RawKind
](mut cursor: JsonCursor) raises DeserializationError -> LazyRaw[
    ImmutAnyOrigin, kind
]:
    var d = JsonDeserializer(cursor=Pointer(to=cursor))
    return deserialize[LazyRaw[ImmutAnyOrigin, kind]](d)


def test_raw_bytes_str_keeps_quotes() raises:
    # The span is the raw wire token, so the quotes are part of it — callers
    # that want the contents strip them (EmberJson's `unsafe_as_string_slice`).
    var cursor = JsonCursor(String('"hi"'), 0)
    var lz = _borrow[RawKind.Str](cursor)
    assert_equal(String(lz.as_slice()), String('"hi"'))


def test_raw_bytes_int() raises:
    var cursor = JsonCursor(String("-42"), 0)
    var lz = _borrow[RawKind.Integer](cursor)
    assert_equal(String(lz.as_slice()), String("-42"))


def test_raw_bytes_float() raises:
    var cursor = JsonCursor(String("3.5e2"), 0)
    var lz = _borrow[RawKind.Float](cursor)
    assert_equal(String(lz.as_slice()), String("3.5e2"))


def test_raw_bytes_seq() raises:
    var cursor = JsonCursor(String("[1, 2, [3]]"), 0)
    var lz = _borrow[RawKind.Seq](cursor)
    assert_equal(String(lz.as_slice()), String("[1, 2, [3]]"))


def test_raw_bytes_map() raises:
    var cursor = JsonCursor(String('{"a": {"b": 1}}'), 0)
    var lz = _borrow[RawKind.Map](cursor)
    assert_equal(String(lz.as_slice()), String('{"a": {"b": 1}}'))


def test_raw_bytes_any_accepts_any_shape() raises:
    var cursor = JsonCursor(String("true"), 0)
    var lz = _borrow[RawKind.Any](cursor)
    assert_equal(String(lz.as_slice()), String("true"))


def test_raw_bytes_str_with_escape() raises:
    # An escaped quote must not end the token early.
    var cursor = JsonCursor(String('"a\\"b"'), 0)
    var lz = _borrow[RawKind.Str](cursor)
    assert_equal(String(lz.as_slice()), String('"a\\"b"'))


def test_int_kind_rejects_float() raises:
    # Fail-fast validation: this is what a single generic `raw_value_bytes`
    # would have silently accepted, deferring the error to `get`.
    var cursor = JsonCursor(String("1.5"), 0)
    with assert_raises():
        _ = _borrow[RawKind.Integer](cursor)


def test_str_kind_rejects_number() raises:
    var cursor = JsonCursor(String("12"), 0)
    with assert_raises():
        _ = _borrow[RawKind.Str](cursor)


def test_map_kind_rejects_seq() raises:
    var cursor = JsonCursor(String("[1]"), 0)
    with assert_raises():
        _ = _borrow[RawKind.Map](cursor)


def test_borrowed_span_aliases_the_input() raises:
    # The defining property: no copy. The returned span must point *into* the
    # cursor's own buffer, not at freshly allocated bytes.
    var cursor = JsonCursor(String('   "borrowed"'), 0)
    var base = Int(cursor.buf.unsafe_ptr())
    var limit = base + cursor.buf.byte_length()
    var lz = _borrow[RawKind.Str](cursor)
    assert_true(lz.address() >= base)
    assert_true(lz.address() < limit)


def test_cursor_advances_past_borrowed_value() raises:
    # The borrow consumes the value, so a following read starts after it.
    var cursor = JsonCursor(String('["a", "b"]'), 0)
    var d = JsonDeserializer(cursor=Pointer(to=cursor))
    var st = d.begin_seq()
    _ = st.has_next()
    var first = st.expect_element[LazyRaw[ImmutAnyOrigin, RawKind.Str]]()
    assert_equal(String(first.as_slice()), String('"a"'))
    _ = st.has_next()
    var second = st.expect_element[LazyRaw[ImmutAnyOrigin, RawKind.Str]]()
    assert_equal(String(second.as_slice()), String('"b"'))


def test_deferred_parse_of_borrowed_bytes() raises:
    # Laziness end to end: borrow the map's bytes, then interpret them later
    # by feeding the span back through a fresh deserializer.
    var cursor = JsonCursor(String('{"x": 7}'), 0)
    var lz = _borrow[RawKind.Map](cursor)

    var inner = JsonCursor(String(lz.as_slice()), 0)
    var d = JsonDeserializer(cursor=Pointer(to=inner))
    var st = d.begin_map()
    _ = st.has_next()
    assert_equal(st.expect_key[String](), String("x"))
    assert_equal(st.expect_value[Int64](), Int64(7))


def test_conformance_relationships() raises:
    assert_true(conforms_to(JsonDeserializer[MutAnyOrigin], Deserializer))
    assert_true(
        conforms_to(JsonDeserializer[MutAnyOrigin], BorrowingDeserializer)
    )
    # A format with no borrowable byte view is still a `Deserializer`; the
    # sub-trait is what `LazyRaw`'s comptime assert screens on.
    assert_true(conforms_to(TokenDeserializer[MutAnyOrigin], Deserializer))
    assert_false(
        conforms_to(TokenDeserializer[MutAnyOrigin], BorrowingDeserializer)
    )


def main() raises:
    TestSuite.discover_tests[__functions_in_module()]().run()
