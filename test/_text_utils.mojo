from std.collections.string import Codepoint
from emberserde.error import DeserializationError, DerErrorKind

comptime _HEX: StaticString = "0123456789ABCDEF"


def _invalid(message: String) -> DeserializationError:
    return DeserializationError(message, DerErrorKind.InvalidValue)


def is_digit(c: Int) -> Bool:
    return c >= ord("0") and c <= ord("9")


def is_number_char(c: Int) -> Bool:
    return (
        is_digit(c)
        or c == ord("-")
        or c == ord("+")
        or c == ord(".")
        or c == ord("e")
        or c == ord("E")
    )


# The value of hex digit `c`, or -1 when it is not one.
def hex_value(c: Int) -> Int:
    if is_digit(c):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    return -1


def codepoint_string(cp: Int) -> String:
    return String(Codepoint(unsafe_unchecked_codepoint=UInt32(cp)))


# A double-quoted string valid in both JSON and TOML: `"`, `\` and control
# characters are escaped, everything else is written as is.
def write_quoted(mut out: String, v: StringSlice):
    var b = v.as_bytes()
    var run = 0
    out += '"'
    for i in range(len(b)):
        var c = Int(b[i])
        var rep: String
        if c == ord('"'):
            rep = '\\"'
        elif c == ord("\\"):
            rep = "\\\\"
        elif c == ord("\n"):
            rep = "\\n"
        elif c == ord("\t"):
            rep = "\\t"
        elif c == ord("\r"):
            rep = "\\r"
        elif c < 0x20 or c == 0x7F:
            rep = String("\\u00") + _HEX[byte=c >> 4] + _HEX[byte=c & 0xF]
        else:
            continue
        out += StringSlice(unsafe_from_utf8=b[run:i])
        out += rep
        run = i + 1
    out += StringSlice(unsafe_from_utf8=b[run:])
    out += '"'


@fieldwise_init
struct TextCursor(Movable):
    var buf: String
    var pos: Int

    def at_end(self) -> Bool:
        return self.pos >= self.buf.byte_length()

    # The byte `k` past the cursor, or -1 past the end.
    def peek(self, k: Int = 0) -> Int:
        var b = self.buf.as_bytes()
        return Int(b[self.pos + k]) if self.pos + k < len(b) else -1

    def advance(mut self):
        self.pos += 1

    # Built from the byte range rather than per-byte `chr()`, which would
    # re-encode each byte of a multi-byte character. Offsets sit on ASCII
    # delimiters, so the range is valid UTF-8.
    def slice(self, start: Int, end: Int) -> String:
        return String(
            StringSlice(unsafe_from_utf8=self.buf.as_bytes()[start:end])
        )

    def skip_ws(mut self):
        while True:
            var c = self.peek()
            if (
                c != ord(" ")
                and c != ord("\t")
                and c != ord("\n")
                and c != ord("\r")
            ):
                return
            self.pos += 1

    def starts_with(self, lit: StringSlice) -> Bool:
        var lb = lit.as_bytes()
        for i in range(len(lb)):
            if self.peek(i) != Int(lb[i]):
                return False
        return True

    def expect_lit(mut self, lit: StringSlice) raises DeserializationError:
        if not self.starts_with(lit):
            raise _invalid(String("expected '") + lit + "'")
        self.pos += lit.byte_length()

    # The grammar is left to `checked_scalar`.
    def read_number(mut self) -> String:
        var start = self.pos
        while is_number_char(self.peek()):
            self.pos += 1
        return self.slice(start, self.pos)

    # The double-quoted string at the cursor, through its closing quote.
    # JSON and TOML escapes differ only in `\/` (JSON) and `\U` (TOML), and
    # TOML allows a raw tab but not DEL.
    # ponytail: JSON surrogate pairs (`😀`) are rejected; join them
    # here if a test needs non-BMP `\u` escapes in JSON.
    def read_quoted[
        toml: Bool = False
    ](mut self) raises DeserializationError -> String:
        self.expect_lit('"')
        var result = String()
        var run = self.pos
        while True:
            var c = self.peek()
            if c == -1 or c == ord("\n") or c == ord("\r"):
                raise _invalid("unterminated string")
            if c == ord('"'):
                result += self.slice(run, self.pos)
                self.pos += 1
                return result^
            if c == ord("\\"):
                result += self.slice(run, self.pos)
                result += self._escape[toml]()
                run = self.pos
                continue
            if (c < 0x20 and not (toml and c == ord("\t"))) or (
                toml and c == 0x7F
            ):
                raise _invalid("control character in a string")
            self.pos += 1

    def _escape[toml: Bool](mut self) raises DeserializationError -> String:
        var e = self.peek(1)
        self.pos += 2
        if e == ord('"'):
            return '"'
        if e == ord("\\"):
            return "\\"
        if e == ord("b"):
            return chr(8)
        if e == ord("f"):
            return chr(12)
        if e == ord("n"):
            return "\n"
        if e == ord("r"):
            return "\r"
        if e == ord("t"):
            return "\t"
        if not toml and e == ord("/"):
            return "/"
        if e == ord("u") or (toml and e == ord("U")):
            var cp = 0
            for _ in range(4 if e == ord("u") else 8):
                var h = hex_value(self.peek())
                if h < 0:
                    raise _invalid("invalid unicode escape")
                cp = cp * 16 + h
                self.pos += 1
            if cp > 0x10FFFF or (cp >= 0xD800 and cp <= 0xDFFF):
                raise _invalid("unicode escape is not a scalar value")
            return codepoint_string(cp)
        raise _invalid("invalid escape")
