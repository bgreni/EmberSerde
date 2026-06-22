@fieldwise_init
struct RenamePolicy(Equatable, ImplicitlyCopyable, Writable):
    var _value: Int

    comptime SnakeCase = Self(0)
    comptime CamelCase = Self(1)
    comptime PascalCase = Self(2)
    comptime KebabCase = Self(3)
    comptime ScreamingSnakeCase = Self(4)
    comptime ScreamingKebabCase = Self(5)
    comptime LowerCase = Self(6)
    comptime UpperCase = Self(7)

    def __eq__(self, other: Self) -> Bool:
        return self._value == other._value

    def __ne__(self, other: Self) -> Bool:
        return self._value != other._value

    def write_to(self, mut writer: Some[Writer]):
        if self == Self.SnakeCase:
            writer.write("SnakeCase")
        elif self == Self.CamelCase:
            writer.write("CamelCase")
        elif self == Self.PascalCase:
            writer.write("PascalCase")
        elif self == Self.KebabCase:
            writer.write("KebabCase")
        elif self == Self.ScreamingSnakeCase:
            writer.write("ScreamingSnakeCase")
        elif self == Self.ScreamingKebabCase:
            writer.write("ScreamingKebabCase")
        elif self == Self.LowerCase:
            writer.write("LowerCase")
        elif self == Self.UpperCase:
            writer.write("UpperCase")
        else:
            writer.write("RenamePolicy(", self._value, ")")


# A struct annotates its field-naming convention by conforming to `RenameAll`
# and declaring `FieldRenamePolicy`. The reflection default reads it via
# `downcast` (Mojo
# can't reflect on parameters), the same mechanism `Field` uses for its members.
trait RenameAll:
    comptime FieldRenamePolicy: RenamePolicy


# Raised-on instead of ignored: an unknown wire field makes deserialization fail.
trait DenyUnknownFields:
    pass


def _is_upper(c: Int) -> Bool:
    return c >= ord("A") and c <= ord("Z")


def _is_lower(c: Int) -> Bool:
    return c >= ord("a") and c <= ord("z")


def _is_digit(c: Int) -> Bool:
    return c >= ord("0") and c <= ord("9")


def _to_lower(c: Int) -> Int:
    return c + 32 if _is_upper(c) else c


# Split a declared field name into lowercased words, inferring boundaries rather
# than assuming any one input convention: separators (`_`/`-`) split, and so do
# case transitions (`fooBar`, `HTTPServer` -> `http`, `server`). So the same
# policy works whether the field was written snake_case, camelCase, PascalCase,
# etc. — we do not assume snake_case input.
def _split_words(name: StringSlice) -> List[String]:
    var words = List[String]()
    var cur = String()
    var bytes = name.as_bytes()
    var n = len(bytes)
    for i in range(n):
        var c = Int(bytes[i])
        if c == ord("_") or c == ord("-"):
            if cur.byte_length() != 0:
                words.append(cur^)
                cur = String()
            continue
        if cur.byte_length() != 0:
            var prev = Int(bytes[i - 1])
            var nxt = Int(bytes[i + 1]) if i + 1 < n else 0
            var boundary = (
                _is_upper(c) and (_is_lower(prev) or _is_digit(prev))
            ) or (_is_upper(c) and _is_upper(prev) and _is_lower(nxt))
            if boundary:
                words.append(cur^)
                cur = String()
        cur += chr(_to_lower(c))
    if cur.byte_length() != 0:
        words.append(cur^)
    return words^


# Capitalize the first codepoint of an already-lowercased `word`.
def _capitalize(word: String) -> String:
    var out = String()
    var first = True
    for cp in word.codepoint_slices():
        if first:
            out += String(cp).upper()
            first = False
        else:
            out += String(cp)
    return out^


# Convert a declared field name to its wire form under `policy`, matching
# serde's `rename_all`. The name is tokenized into words first (see
# `_split_words`), so the input convention does not matter.
def apply_rename_policy[policy: RenamePolicy](declared: StaticString) -> String:
    var words = _split_words(declared)
    var out = String()
    for i in range(len(words)):
        comptime if policy == RenamePolicy.SnakeCase:
            if i > 0:
                out += "_"
            out += words[i]
        elif policy == RenamePolicy.ScreamingSnakeCase:
            if i > 0:
                out += "_"
            out += words[i].upper()
        elif policy == RenamePolicy.KebabCase:
            if i > 0:
                out += "-"
            out += words[i]
        elif policy == RenamePolicy.ScreamingKebabCase:
            if i > 0:
                out += "-"
            out += words[i].upper()
        elif policy == RenamePolicy.LowerCase:
            out += words[i]
        elif policy == RenamePolicy.UpperCase:
            out += words[i].upper()
        elif policy == RenamePolicy.CamelCase:
            out += words[i] if i == 0 else _capitalize(words[i])
        elif policy == RenamePolicy.PascalCase:
            out += _capitalize(words[i])
        else:
            comptime assert False, String(t"Unsupported rename policy {policy}")
    return out^
