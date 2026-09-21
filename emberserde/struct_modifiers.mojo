from std.builtin.rebind import downcast
from std.reflection import reflect


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


# A stable wire tag for a type used as a `Variant` arm. Without it the tag is
# `reflect[AT].name()` — a canonical name that embeds module paths and stdlib
# spellings (`Int64` renders as `SIMD[DType.int64, 1]`), so moving a type
# between modules or a stdlib respelling silently breaks the wire. Read via
# `downcast` the way `FieldMeta` is. Note that name tags are best treated as
# debug/diagnostic; the arm *index* (also on the `begin_enum` surface) is the
# stable default real formats should key on.
trait ArmName:
    comptime serde_arm_name: StaticString


# The tag `AT` rides the wire under when it is a `Variant` arm: its declared
# `ArmName`, or its canonical `reflect` name as the fallback.
def arm_tag[AT: AnyType]() -> String:
    comptime if conforms_to(AT, ArmName):
        return String(downcast[AT, ArmName].serde_arm_name)
    return String(reflect[AT].name())


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
        var c = Codepoint(bytes[i])
        if c == Codepoint("_") or c == Codepoint("-"):
            if cur.byte_length() != 0:
                words.append(cur^)
                cur = String()
            continue
        if cur.byte_length() != 0:
            var prev = Codepoint(bytes[i - 1])
            var nxt = Codepoint(bytes[i + 1] if i + 1 < n else 0)
            var boundary = c.is_ascii_upper() and (
                prev.is_ascii_lower()
                or prev.is_ascii_digit()
                or (prev.is_ascii_upper() and nxt.is_ascii_lower())
            )
            if boundary:
                words.append(cur^)
                cur = String()
        cur += String(c).lower()
    if cur.byte_length() != 0:
        words.append(cur^)
    return words^


# Capitalize the first codepoint of an already-lowercased `word`.
def _capitalize(word: String) -> String:
    return word[codepoint=0:1].upper() + word[codepoint=1:]


# Convert a declared field name to its wire form under `policy`, matching
# serde's `rename_all`. The name is tokenized into words first (see
# `_split_words`), so the input convention does not matter.
def apply_rename_policy[policy: RenamePolicy](declared: StaticString) -> String:
    comptime P = RenamePolicy
    comptime assert 0 <= policy._value <= 7, String(
        t"Unsupported rename policy {policy}"
    )
    comptime snake = policy == P.SnakeCase or policy == P.ScreamingSnakeCase
    comptime kebab = policy == P.KebabCase or policy == P.ScreamingKebabCase
    comptime screaming = (
        policy == P.ScreamingSnakeCase or policy == P.ScreamingKebabCase
    )
    comptime sep: StaticString = "_" if snake else "-" if kebab else ""
    comptime upper = screaming or policy == P.UpperCase
    comptime capitalize_from = (
        0 if policy == P.PascalCase else 1 if policy == P.CamelCase else Int.MAX
    )
    var words = _split_words(declared)
    var out = String()
    for i in range(len(words)):
        if i > 0:
            out += sep
        comptime if upper:
            out += words[i].upper()
        else:
            out += _capitalize(words[i]) if i >= capitalize_from else words[i]
    return out^
