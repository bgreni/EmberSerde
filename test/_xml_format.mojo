# A non-shipping, test-only XML format: a conforming non-validating XML 1.0
# (Fifth Edition) processor with Namespaces in XML 1.0 (Third Edition).
# Reading streams in one pass over a pull parser; a field that comes back
# later (an interleaved list, a second map entry) is the framework's to
# append under `RepeatPolicy.AppendSeqs`, and a repeated singular element is
# its `DuplicateField`.
#
# External subsets and external entities are never read. A reference that
# would need one is an error (`InvalidValue`, "unsupported: ..."), and so,
# after an unread external parameter entity, the internal subset's later
# ENTITY/ATTLIST declarations go unprocessed (§5.1) unless
# `standalone="yes"`. Inputs are UTF-8, UTF-16, ISO-8859-1 or US-ASCII.
# Entity expansion stops, like expat's billion-laughs guard, once the input
# plus everything expanded reaches 8 MiB and exceeds 100 times the input.
#
# Wire form (compact out): a struct is an element with one child per field,
# `XmlAttr` fields as attributes and an `XmlText` field as its text. A list
# field is its elements, one element each under the field's name; a map
# field is one `<name><key/><value/></name>` per entry; a tuple is `<item>`
# children; a variant is `<name variant="Arm">payload</name>`. An absent
# `Optional` field is omitted, and `nil="true"` marks `None` where an element
# must be written (inside lists and tuples, at the root). Inside a list or
# tuple, a nested list is boxed as `<item>` children and a map as `<entry>`
# children. An `XmlMixed` field is its element's whole content in document
# order. Bytes are lowercase hex. Names match by expanded name: a field's
# element is in its `XmlNs`, else its struct's; an attribute is in its
# field's `XmlNs`, else no namespace. The root element's name and namespace
# are not checked, and the mapping's own `item`/`entry`/`key`/`value`
# elements and `nil`/`variant` attributes match by local name.

from std.collections.string import Codepoint
from std.collections.string.string_span import get_static_string
from std.reflection import reflect

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
    RepeatPolicy,
    _fill_if_missing,
    checked_scalar,
    deserialize,
)
from emberserde.error import (
    SerializationError,
    SerErrorKind,
    DeserializationError,
    DerErrorKind,
)
from emberserde.field import Rename
from emberserde.field_meta import (
    count_annotations,
    field_annotations,
    is_skipped,
    name_matches,
    static_wire_name,
)
from emberserde.struct_modifiers import (
    DenyUnknownFields,
    arm_tag,
    count_struct_annotations,
    struct_annotations,
)
from emberserde.utils import Base


# The field is written as an attribute of its struct's element.
@fieldwise_init
struct XmlAttr(Base):
    pass


# The field is its struct element's text content. At most one per struct.
@fieldwise_init
struct XmlText(Base):
    pass


# The field is its struct element's whole content in document order, as a
# `List` of `Variant`s: each run of text is the `XmlTextRun` arm and each
# child element the struct arm whose `Rename` is its name (in the field's
# namespace). The struct can then have no other child-element or text field.
@fieldwise_init
struct XmlMixed(Base):
    pass


# One run of text in an `XmlMixed` field; `#text` can't be an element name.
@__annotation(Rename("#text"))
@fieldwise_init
struct XmlTextRun(Copyable, Deserializable, Movable, Serializable):
    var text: String

    @staticmethod
    def deserialize(
        mut d: Some[Deserializer],
    ) raises DeserializationError -> Self:
        return Self(d.expect_string())

    def serialize(self, mut s: Some[Serializer]) raises SerializationError:
        s.serialize_string(self.text)


# On a struct, the namespace of its element (at the root) and the default
# for its child-element fields; on a field, the namespace of that field's
# element or attribute.
@fieldwise_init
struct XmlNs(Base):
    var uri: StaticString


comptime XML_NS: StaticString = "http://www.w3.org/XML/1998/namespace"
comptime XMLNS_NS: StaticString = "http://www.w3.org/2000/xmlns/"

# Positions a value can be written at / read from.
comptime _FIELD = 0
comptime _ELEMENT = 1
comptime _TEXT = 2
comptime _ATTR = 3
comptime _EMPTY = 4
# An `XmlMixed` field, and one element of it (an element, or `_TEXT_PART` a
# run of text).
comptime _MIXED = 5
comptime _PART = 6
comptime _TEXT_PART = 7

comptime _HEX: StaticString = "0123456789abcdef"


# At most one `XmlMixed` field, beside nothing but attribute fields.
def _mixed_ok[T: AnyType]() -> Bool:
    var mixed = 0
    var other = 0
    comptime for i in range(reflect[T].field_count()):
        comptime if count_annotations[T, i, XmlMixed]() > 0:
            mixed += 1
        elif not is_skipped[T, i]() and count_annotations[T, i, XmlAttr]() == 0:
            other += 1
    return mixed == 0 or (mixed == 1 and other == 0)


comptime _MIXED_SHAPE: StaticString = (
    "an XmlMixed field must be a List of Variants"
)


def _struct_ns[T: AnyType]() -> String:
    comptime anns = struct_annotations[T]
    comptime Ts = type_of(anns).Ts
    comptime for j in range(Ts.length):
        comptime if Ts[j] == XmlNs:
            comptime u = rebind[XmlNs](anns[j]).uri
            return String(u)
    return String()


def _field_ns[T: AnyType, i: Int]() -> Optional[String]:
    comptime anns = field_annotations[T, i]
    comptime Ts = type_of(anns).Ts
    comptime for j in range(Ts.length):
        comptime if Ts[j] == XmlNs:
            comptime u = rebind[XmlNs](anns[j]).uri
            return String(u)
    return None


def _elem_ns[T: AnyType, i: Int]() -> String:
    var ns = _field_ns[T, i]()
    return ns.value() if ns else _struct_ns[T]()


def _attr_ns[T: AnyType, i: Int]() -> String:
    var ns = _field_ns[T, i]()
    return ns.value() if ns else String()


# ----------------------------------------------------------------------------
# Characters and names
# ----------------------------------------------------------------------------


def _is_char(c: Int) -> Bool:
    return (
        c == 0x9
        or c == 0xA
        or c == 0xD
        or (c >= 0x20 and c <= 0xD7FF)
        or (c >= 0xE000 and c <= 0xFFFD)
        or (c >= 0x10000 and c <= 0x10FFFF)
    )


def _is_s(c: Int) -> Bool:
    return c == 0x20 or c == 0x9 or c == 0xA or c == 0xD


def _is_name_start(c: Int) -> Bool:
    return (
        c == ord(":")
        or (c >= ord("A") and c <= ord("Z"))
        or c == ord("_")
        or (c >= ord("a") and c <= ord("z"))
        or (c >= 0xC0 and c <= 0xD6)
        or (c >= 0xD8 and c <= 0xF6)
        or (c >= 0xF8 and c <= 0x2FF)
        or (c >= 0x370 and c <= 0x37D)
        or (c >= 0x37F and c <= 0x1FFF)
        or (c >= 0x200C and c <= 0x200D)
        or (c >= 0x2070 and c <= 0x218F)
        or (c >= 0x2C00 and c <= 0x2FEF)
        or (c >= 0x3001 and c <= 0xD7FF)
        or (c >= 0xF900 and c <= 0xFDCF)
        or (c >= 0xFDF0 and c <= 0xFFFD)
        or (c >= 0x10000 and c <= 0xEFFFF)
    )


def _is_name_char(c: Int) -> Bool:
    return (
        _is_name_start(c)
        or c == ord("-")
        or c == ord(".")
        or (c >= ord("0") and c <= ord("9"))
        or c == 0xB7
        or (c >= 0x300 and c <= 0x36F)
        or (c >= 0x203F and c <= 0x2040)
    )


def _is_pubid_char(c: Int) -> Bool:
    if (
        (c >= ord("a") and c <= ord("z"))
        or (c >= ord("A") and c <= ord("Z"))
        or (c >= ord("0") and c <= ord("9"))
    ):
        return True
    if c == 0x20 or c == 0xD or c == 0xA:
        return True
    var punct = StaticString("-'()+,./:=?;!*#@$_%").as_bytes()
    for k in range(len(punct)):
        if Int(punct[k]) == c:
            return True
    return False


def _utf8_len(lead: Int) -> Int:
    if lead < 0x80:
        return 1
    if lead < 0xE0:
        return 2
    if lead < 0xF0:
        return 3
    return 4


# The code point at `i` of valid UTF-8.
def _cp_at(b: Span[Byte, _], i: Int) -> Int:
    var c = Int(b[i])
    if c < 0x80:
        return c
    var n = _utf8_len(c)
    var cp = c & (0x1F if n == 2 else (0x0F if n == 3 else 0x07))
    for k in range(1, n):
        cp = (cp << 6) | (Int(b[i + k]) & 0x3F)
    return cp


def _cp_string(cp: Int) -> String:
    return String(Codepoint(unsafe_unchecked_codepoint=UInt32(cp)))


# The end of the Name at `i`, or `i` when none starts there.
def _name_end(b: Span[Byte, _], i: Int, end: Int) -> Int:
    if i >= end or not _is_name_start(_cp_at(b, i)):
        return i
    var j = i + _utf8_len(Int(b[i]))
    while j < end and _is_name_char(_cp_at(b, j)):
        j += _utf8_len(Int(b[j]))
    return j


def _is_ncname(s: StringSlice) -> Bool:
    var b = s.as_bytes()
    if len(b) == 0 or _name_end(b, 0, len(b)) != len(b):
        return False
    for i in range(len(b)):
        if Int(b[i]) == ord(":"):
            return False
    return True


def _slice(b: Span[Byte, _], start: Int, end: Int) -> String:
    return String(StringSlice(unsafe_from_utf8=b[start:end]))


# An entity reference's name: an entity name, so no colon (Namespaces §7).
def _check_ref_name(name: StringSlice) raises DeserializationError:
    if not _is_ncname(name):
        raise DeserializationError(
            String(t"not well-formed: entity name '{name}' contains a colon"),
            DerErrorKind.InvalidValue,
        )


def _predefined(name: StringSlice) -> Optional[String]:
    if name == "lt":
        return String("<")
    if name == "gt":
        return String(">")
    if name == "amp":
        return String("&")
    if name == "apos":
        return String("'")
    if name == "quot":
        return String('"')
    return None


# ----------------------------------------------------------------------------
# Serialization
# ----------------------------------------------------------------------------


def _ser_error(var message: String) -> SerializationError:
    return SerializationError(message^, SerErrorKind.InvalidValue)


def _check_name(name: StringSlice) raises SerializationError:
    if not _is_ncname(name):
        raise _ser_error(String(t"'{name}' is not a valid XML name"))


# Escapes so a conforming reader gets `v` back exactly: line-end and
# attribute-value normalization would otherwise rewrite CR, tab and newline.
def _escape(
    mut out: String, v: StringSlice, attr: Bool
) raises SerializationError:
    var b = v.as_bytes()
    var n = len(b)
    var run = 0
    for i in range(n):
        var c = Int(b[i])
        var rep: StaticString
        if c == ord("&"):
            rep = "&amp;"
        elif c == ord("<"):
            rep = "&lt;"
        elif c == ord(">"):
            rep = "&gt;"
        elif c == 0xD:
            rep = "&#13;"
        elif attr and c == ord('"'):
            rep = "&quot;"
        elif attr and c == ord("'"):
            rep = "&apos;"
        elif attr and c == 0x9:
            rep = "&#9;"
        elif attr and c == 0xA:
            rep = "&#10;"
        elif c < 0x20 and c != 0x9 and c != 0xA:
            raise _ser_error(String(t"character U+{c} can't be written in XML"))
        elif (
            c == 0xEF
            and i + 2 < n
            and b[i + 1] == 0xBF
            and (b[i + 2] == 0xBE or b[i + 2] == 0xBF)
        ):
            raise _ser_error(
                String("U+FFFE and U+FFFF can't be written in XML")
            )
        else:
            continue
        out += StringSlice(unsafe_from_utf8=b[run:i])
        out += rep
        run = i + 1
    out += StringSlice(unsafe_from_utf8=b[run:])


def _ns_decl(ns: String, scope: String) raises SerializationError -> String:
    if ns == scope:
        return String()
    var d = String(' xmlns="')
    _escape(d, ns, True)
    return d + '"'


def _struct_tag[T: AnyType]() -> String:
    comptime if count_struct_annotations[T, Rename]() > 0:
        return arm_tag[T]()
    else:
        return String(reflect[T].base_name())


def _shape_error(what: StaticString) -> SerializationError:
    return SerializationError(
        String(t"{what} can't be an XML attribute or text"),
        SerErrorKind.InvalidValue,
    )


@fieldwise_init
struct XmlSeqSer[origin: MutOrigin](SeqSerState):
    var out: Pointer[String, Self.origin]
    var item: String
    # The boxing element to close, empty when the list is unwrapped.
    var close: String
    var ns: String
    var scope: String
    # An `XmlMixed` field's list: its elements are parts of the content.
    var mixed: Bool

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = XmlSerializer(
            out=self.out,
            name=self.item.copy(),
            mode=_PART if self.mixed else _ELEMENT,
            extra=String(),
            ns=self.ns.copy(),
            scope=self.scope.copy(),
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        if self.close:
            self.out[] += "</" + self.close + ">"


@fieldwise_init
struct XmlMapSer[origin: MutOrigin](MapSerState):
    var out: Pointer[String, Self.origin]
    var entry: String
    var close: String
    var ns: String
    var scope: String

    def serialize_key(mut self, k: Some[AnyType]) raises SerializationError:
        self.out[] += "<" + self.entry + _ns_decl(self.ns, self.scope) + ">"
        var sub = XmlSerializer(
            out=self.out,
            name=String("key"),
            mode=_FIELD,
            extra=String(),
            ns=self.ns.copy(),
            scope=self.ns.copy(),
        )
        serialize(k, sub)

    def serialize_value(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = XmlSerializer(
            out=self.out,
            name=String("value"),
            mode=_FIELD,
            extra=String(),
            ns=self.ns.copy(),
            scope=self.ns.copy(),
        )
        serialize(v, sub)
        self.out[] += "</" + self.entry + ">"

    def end(mut self) raises SerializationError:
        if self.close:
            self.out[] += "</" + self.close + ">"


# Attributes must precede children in the start tag whatever the field
# order, so each part is buffered until `end`.
@fieldwise_init
struct XmlStructSer[origin: MutOrigin](StructSerState):
    var out: Pointer[String, Self.origin]
    var tag: String
    var attrs: String
    var text: String
    var children: String
    # The element's namespace, which is the default in scope for its
    # children; namespaced attributes get a prefix declared here.
    var ns: String
    var prefixes: List[String]

    def _prefix(mut self, uri: String) raises SerializationError -> String:
        for k in range(len(self.prefixes)):
            if self.prefixes[k] == uri:
                return String(t"ns{k}")
        var p = String(t"ns{len(self.prefixes)}")
        self.prefixes.append(uri.copy())
        self.attrs += " xmlns:" + p + '="'
        _escape(self.attrs, uri, True)
        self.attrs += '"'
        return p^

    def serialize_field[
        T: AnyType, idx: Int
    ](
        mut self, field_name: StringSlice, v: Some[AnyType]
    ) raises SerializationError:
        _check_name(field_name)
        comptime if count_annotations[T, idx, XmlAttr]() > 0:
            var ans = _attr_ns[T, idx]()
            var qname = String(field_name)
            if ans:
                qname = self._prefix(ans) + ":" + qname
            var sub = XmlSerializer(
                out=Pointer(to=self.attrs),
                name=qname^,
                mode=_ATTR,
                extra=String(),
                ns=ans^,
                scope=String(),
            )
            serialize(v, sub)
        elif count_annotations[T, idx, XmlText]() > 0:
            var sub = XmlSerializer(
                out=Pointer(to=self.text),
                name=String(field_name),
                mode=_TEXT,
                extra=String(),
                ns=String(),
                scope=String(),
            )
            serialize(v, sub)
        elif count_annotations[T, idx, XmlMixed]() > 0:
            var sub = XmlSerializer(
                out=Pointer(to=self.children),
                name=String(field_name),
                mode=_MIXED,
                extra=String(),
                ns=_elem_ns[T, idx](),
                scope=self.ns.copy(),
            )
            serialize(v, sub)
        else:
            var sub = XmlSerializer(
                out=Pointer(to=self.children),
                name=String(field_name),
                mode=_FIELD,
                extra=String(),
                ns=_elem_ns[T, idx](),
                scope=self.ns.copy(),
            )
            serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "<" + self.tag + self.attrs
        if not self.text and not self.children:
            self.out[] += "/>"
            return
        self.out[] += ">" + self.text + self.children + "</" + self.tag + ">"


@fieldwise_init
struct XmlTupleSer[origin: MutOrigin](TupleSerState):
    var out: Pointer[String, Self.origin]
    var close: String
    var ns: String

    def serialize_element(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = XmlSerializer(
            out=self.out,
            name=String("item"),
            mode=_ELEMENT,
            extra=String(),
            ns=self.ns.copy(),
            scope=self.ns.copy(),
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        self.out[] += "</" + self.close + ">"


@fieldwise_init
struct XmlEnumSer[origin: MutOrigin](EnumSerState):
    var out: Pointer[String, Self.origin]
    var name: String
    var extra: String
    var ns: String
    var scope: String
    # A text run in mixed content: the payload is written as text.
    var text: Bool

    # The payload shares the variant's element, so a struct payload's own
    # attributes land next to the `variant` tag.
    def serialize_payload(mut self, v: Some[AnyType]) raises SerializationError:
        var sub = XmlSerializer(
            out=self.out,
            name=self.name.copy(),
            mode=_TEXT if self.text else _ELEMENT,
            extra=self.extra.copy(),
            ns=self.ns.copy(),
            scope=self.scope.copy(),
        )
        serialize(v, sub)

    def end(mut self) raises SerializationError:
        pass


# One value at one position. The element (or attribute) name is supplied by
# the parent; at the root it is empty and resolved from the value itself.
@fieldwise_init
struct XmlSerializer[origin: MutOrigin](Serializer):
    var out: Pointer[String, Self.origin]
    var name: String
    var mode: Int
    # Attribute text to add to this value's start tag (a variant's tag).
    var extra: String
    # The namespace of this value's element (or attribute), and the default
    # namespace in scope where it is written.
    var ns: String
    var scope: String

    comptime MapType = XmlMapSer[Self.origin]
    comptime SeqType = XmlSeqSer[Self.origin]
    comptime StructType = XmlStructSer[Self.origin]
    comptime TupleType = XmlTupleSer[Self.origin]
    comptime EnumType = XmlEnumSer[Self.origin]

    def _tag(self) raises SerializationError -> String:
        var tag = self.name.copy() if self.name else String("value")
        _check_name(tag)
        return tag^

    # A start tag's opening, through its attributes.
    def _start(self, tag: String) raises SerializationError -> String:
        return "<" + tag + _ns_decl(self.ns, self.scope) + self.extra

    def _leaf(mut self, text: StringSlice) raises SerializationError:
        if self.mode == _MIXED or self.mode == _PART:
            raise _ser_error(String(_MIXED_SHAPE))
        if self.mode == _ATTR:
            self.out[] += " " + self.name + '="'
            _escape(self.out[], text, True)
            self.out[] += '"'
        elif self.mode == _TEXT:
            _escape(self.out[], text, False)
        else:
            var tag = self._tag()
            self.out[] += self._start(tag)
            if text.byte_length() == 0:
                self.out[] += "/>"
            else:
                self.out[] += ">"
                _escape(self.out[], text, False)
                self.out[] += "</" + tag + ">"

    # Writes a container's start tag and returns the name to close it with.
    def _open(mut self, what: StaticString) raises SerializationError -> String:
        if self.mode == _MIXED or self.mode == _PART:
            raise _ser_error(String(_MIXED_SHAPE))
        if self.mode == _ATTR or self.mode == _TEXT:
            raise _shape_error(what)
        var tag = self._tag()
        self.out[] += self._start(tag) + ">"
        return tag^

    def serialize_bool(mut self, v: Bool) raises SerializationError:
        self._leaf("true" if v else "false")

    def serialize_number[
        dt: DType, //
    ](mut self, v: Scalar[dt]) raises SerializationError:
        self._leaf(String(v))

    def serialize_string(mut self, v: StringSlice) raises SerializationError:
        self._leaf(v)

    def serialize_bytes(mut self, v: Span[Byte, _]) raises SerializationError:
        var hex = String()
        for i in range(len(v)):
            hex += chr(Int(_HEX.as_bytes()[Int(v[i] >> 4)]))
            hex += chr(Int(_HEX.as_bytes()[Int(v[i] & 15)]))
        self._leaf(hex)

    # An omitted field or attribute already reads back as `None`; only an
    # element that must exist (a list or tuple member, the root) says so.
    def serialize_none(mut self) raises SerializationError:
        if self.mode == _PART:
            raise _ser_error(String(_MIXED_SHAPE))
        if self.mode == _ELEMENT:
            self.out[] += self._start(self._tag()) + ' nil="true"/>'

    def begin_seq(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.SeqType:
        if self.mode == _FIELD:
            return XmlSeqSer(
                out=self.out,
                item=self.name.copy(),
                close=String(),
                ns=self.ns.copy(),
                scope=self.scope.copy(),
                mixed=False,
            )
        if self.mode == _MIXED:
            return XmlSeqSer(
                out=self.out,
                item=String(),
                close=String(),
                ns=self.ns.copy(),
                scope=self.scope.copy(),
                mixed=True,
            )
        var tag = self._open("a list")
        return XmlSeqSer(
            out=self.out,
            item=String("item"),
            close=tag^,
            ns=self.ns.copy(),
            scope=self.ns.copy(),
            mixed=False,
        )

    def begin_map(
        mut self, size_hint: Optional[Int] = None
    ) raises SerializationError -> Self.MapType:
        if self.mode == _FIELD:
            return XmlMapSer(
                out=self.out,
                entry=self.name.copy(),
                close=String(),
                ns=self.ns.copy(),
                scope=self.scope.copy(),
            )
        var tag = self._open("a map")
        return XmlMapSer(
            out=self.out,
            entry=String("entry"),
            close=tag^,
            ns=self.ns.copy(),
            scope=self.ns.copy(),
        )

    def begin_struct[
        T: AnyType
    ](mut self, field_count: Int) raises SerializationError -> Self.StructType:
        comptime assert _mixed_ok[T](), (
            "a struct with an XmlMixed field may have only attribute fields"
            " beside it"
        )
        if self.mode == _MIXED or self.mode == _PART:
            raise _ser_error(String(_MIXED_SHAPE))
        if self.mode == _ATTR or self.mode == _TEXT:
            raise _shape_error("a struct")
        var tag = self.name.copy() if self.name else _struct_tag[T]()
        _check_name(tag)
        var ns = self.ns.copy() if self.name else _struct_ns[T]()
        return XmlStructSer(
            out=self.out,
            tag=tag^,
            attrs=_ns_decl(ns, self.scope) + self.extra,
            text=String(),
            children=String(),
            ns=ns^,
            prefixes=[],
        )

    def begin_tuple[
        field_count: Int
    ](mut self) raises SerializationError -> Self.TupleType:
        var tag = self._open("a tuple")
        return XmlTupleSer(out=self.out, close=tag^, ns=self.ns.copy())

    def begin_enum[
        T: AnyType, variant: String
    ](mut self, idx: UInt32) raises SerializationError -> Self.EnumType:
        # Mixed content: a text run, or a child element named by its arm.
        if self.mode == _PART:
            if variant == "#text":
                return XmlEnumSer(
                    out=self.out,
                    name=String(),
                    extra=String(),
                    ns=String(),
                    scope=String(),
                    text=True,
                )
            if not _is_ncname(variant):
                raise _ser_error(
                    String(
                        t"mixed content arm '{variant}' needs a struct Rename"
                        t" to an XML name"
                    )
                )
            return XmlEnumSer(
                out=self.out,
                name=variant,
                extra=String(),
                ns=self.ns.copy(),
                scope=self.scope.copy(),
                text=False,
            )
        if self.mode == _MIXED:
            raise _ser_error(String(_MIXED_SHAPE))
        if self.mode == _ATTR or self.mode == _TEXT:
            raise _shape_error("a variant")
        var extra = self.extra + ' variant="'
        _escape(extra, variant, True)
        extra += '"'
        return XmlEnumSer(
            out=self.out,
            name=self._tag(),
            extra=extra^,
            ns=self.ns.copy(),
            scope=self.scope.copy(),
            text=False,
        )


def to_xml[T: AnyType, //](value: T) raises SerializationError -> String:
    var buf = String()
    var s = XmlSerializer(
        out=Pointer(to=buf),
        name=String(),
        mode=_ELEMENT,
        extra=String(),
        ns=String(),
        scope=String(),
    )
    serialize(value, s)
    return buf^


# ----------------------------------------------------------------------------
# Input: encodings, line ends, characters
# ----------------------------------------------------------------------------


def _wf(var message: String) -> DeserializationError:
    return DeserializationError(
        "not well-formed: " + message, DerErrorKind.InvalidValue
    )


def _unsupported(var message: String) -> DeserializationError:
    return DeserializationError(
        "unsupported: " + message, DerErrorKind.InvalidValue
    )


def _invalid(var message: String) -> DeserializationError:
    return DeserializationError(message^, DerErrorKind.InvalidValue)


def _mismatch(var message: String) -> DeserializationError:
    return DeserializationError(message^, DerErrorKind.TypeMismatch)


def _nibble(c: Int) raises DeserializationError -> Int:
    if c >= ord("0") and c <= ord("9"):
        return c - ord("0")
    if c >= ord("a") and c <= ord("f"):
        return c - ord("a") + 10
    if c >= ord("A") and c <= ord("F"):
        return c - ord("A") + 10
    raise _invalid(String("invalid hex digit"))


# The encoding an XML declaration names, or empty when there is none; `b`
# is ASCII-compatible from `start`.
def _declared_encoding(b: Span[Byte, _], start: Int) -> String:
    var n = len(b)
    if n - start < 6 or _slice(b, start, start + 5) != "<?xml":
        return String()
    if not _is_s(Int(b[start + 5])):
        return String()
    var end = start + 5
    while end + 1 < n and not (
        Int(b[end]) == ord("?") and Int(b[end + 1]) == ord(">")
    ):
        if b[end] >= 0x80:
            return String()
        end += 1
    var decl = _slice(b, start, end)
    var at = Int(decl.find("encoding"))
    if at < 0:
        return String()
    var d = decl.as_bytes()
    var i = at + 8
    while i < len(d) and _is_s(Int(d[i])):
        i += 1
    if i >= len(d) or Int(d[i]) != ord("="):
        return String()
    i += 1
    while i < len(d) and _is_s(Int(d[i])):
        i += 1
    if i >= len(d) or (Int(d[i]) != ord('"') and Int(d[i]) != ord("'")):
        return String()
    var q = d[i]
    var j = i + 1
    while j < len(d) and d[j] != q:
        j += 1
    return _slice(d, i + 1, j).upper()


def _utf16(
    b: Span[Byte, _], start: Int, le: Bool
) raises DeserializationError -> String:
    var out = String()
    var i = start
    if (len(b) - start) % 2 != 0:
        raise _wf("truncated UTF-16")
    while i < len(b):
        var u = (
            Int(b[i])
            | (Int(b[i + 1]) << 8) if le else (Int(b[i]) << 8)
            | Int(b[i + 1])
        )
        i += 2
        if u >= 0xD800 and u <= 0xDBFF:
            if i >= len(b):
                raise _wf("unpaired UTF-16 surrogate")
            var l = (
                Int(b[i])
                | (Int(b[i + 1]) << 8) if le else (Int(b[i]) << 8)
                | Int(b[i + 1])
            )
            if l < 0xDC00 or l > 0xDFFF:
                raise _wf("unpaired UTF-16 surrogate")
            i += 2
            u = 0x10000 + ((u - 0xD800) << 10) + (l - 0xDC00)
        elif u >= 0xDC00 and u <= 0xDFFF:
            raise _wf("unpaired UTF-16 surrogate")
        out += _cp_string(u)
    return out^


def _is_utf16_name(enc: String) -> Bool:
    return enc.startswith("UTF-16") or enc.startswith("UTF16")


# The document's characters, decoded per Appendix F: a byte order mark, else
# the first bytes' shape, then the encoding declaration, which must agree.
def _decode(b: Span[Byte, _]) raises DeserializationError -> String:
    var n = len(b)
    if n >= 2 and (
        (b[0] == 0xFE and b[1] == 0xFF) or (b[0] == 0xFF and b[1] == 0xFE)
    ):
        var le = b[0] == 0xFF
        var text = _utf16(b, 2, le)
        var enc = _declared_encoding(text.as_bytes(), 0)
        if (
            enc != ""
            and enc != "UTF-16"
            and enc != ("UTF-16LE" if le else "UTF-16BE")
        ):
            raise _wf(String(t"declared {enc}, but the input is UTF-16"))
        return text^
    if n >= 4 and (
        (b[0] == 0 and b[1] == 0x3C and b[2] == 0 and b[3] == 0x3F)
        or (b[0] == 0x3C and b[1] == 0 and b[2] == 0x3F and b[3] == 0)
    ):
        var le = b[0] == 0x3C
        var text = _utf16(b, 0, le)
        var enc = _declared_encoding(text.as_bytes(), 0)
        if enc != ("UTF-16LE" if le else "UTF-16BE"):
            raise _wf("UTF-16 without a byte order mark")
        return text^
    var start = 0
    var bom = False
    if n >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
        start = 3
        bom = True
    var enc = _declared_encoding(b, start)
    if enc == "" or enc == "UTF-8" or enc == "UTF8":
        try:
            return String(from_utf8=b[start:])
        except:
            raise _wf("invalid UTF-8")
    if bom or _is_utf16_name(enc):
        raise _wf(String(t"declared {enc}, but the input is UTF-8"))
    if enc == "ISO-8859-1" or enc == "LATIN1" or enc == "ISO_8859-1":
        var out = String()
        for i in range(start, n):
            out += _cp_string(Int(b[i]))
        return out^
    if enc == "US-ASCII" or enc == "ASCII":
        for i in range(start, n):
            if b[i] >= 0x80:
                raise _wf("a non-ASCII byte in US-ASCII input")
        return _slice(b, start, n)
    raise _unsupported(String(t"encoding {enc}"))


# Drops a leading byte order mark, normalizes line ends (§2.11) and checks
# that every character is a `Char`.
def _prepare(text: String) raises DeserializationError -> String:
    var b = text.as_bytes()
    var n = len(b)
    var i = 0
    if n >= 3 and b[0] == 0xEF and b[1] == 0xBB and b[2] == 0xBF:
        i = 3
    var out = String()
    var run = i
    while i < n:
        var c = Int(b[i])
        if c == 0xD:
            out += StringSlice(unsafe_from_utf8=b[run:i])
            out += "\n"
            i += 1
            if i < n and b[i] == 0xA:
                i += 1
            run = i
            continue
        if c < 0x80:
            if not _is_char(c):
                raise _wf(String(t"character U+{c} is not allowed"))
            i += 1
            continue
        var cp = _cp_at(b, i)
        if not _is_char(cp):
            raise _wf(String(t"character U+{cp} is not allowed"))
        i += _utf8_len(c)
    out += StringSlice(unsafe_from_utf8=b[run:n])
    return out^


# ----------------------------------------------------------------------------
# The pull parser
# ----------------------------------------------------------------------------

comptime _START = 0
comptime _END = 1
comptime _TEXT_EV = 2
comptime _PI = 3
comptime _EOF = 4


# An attribute, normalized and defaulted; `uri` is `XMLNS_NS` for a
# namespace declaration.
@fieldwise_init
struct XAttr(Copyable, Movable):
    var qname: String
    var uri: String
    var local: String
    var value: String


# `depth` is the number of open elements around the event: a start tag's
# parent count, and the count inside the element whose text this is.
@fieldwise_init
struct XEvent(Copyable, Movable):
    var kind: Int
    var qname: String
    var uri: String
    var local: String
    var attrs: List[XAttr]
    var text: String
    var depth: Int


def _event(kind: Int, depth: Int, var text: String = String()) -> XEvent:
    return XEvent(kind, String(), String(), String(), [], text^, depth)


@fieldwise_init
struct _Entity(Copyable, Movable):
    var value: String
    var external: Bool
    var unparsed: Bool


@fieldwise_init
struct _AttDef(Copyable, Movable):
    var name: String
    var tokenized: Bool
    var default: Optional[String]


@fieldwise_init
struct _Notation(Copyable, Movable):
    var public_id: Optional[String]
    var system_id: Optional[String]


@fieldwise_init
struct _Frame(Movable):
    var src: String
    var pos: Int
    var entity: String
    var depth: Int


@fieldwise_init
struct _Ref(ImplicitlyCopyable, Movable):
    var cp: Int
    var next: Int


# The character reference whose digits start at `i` (just past "&#").
def _char_ref(
    b: Span[Byte, _], i: Int, end: Int
) raises DeserializationError -> _Ref:
    var hex = i < end and Int(b[i]) == ord("x")
    var j = i + 1 if hex else i
    var v = 0
    var digits = 0
    while j < end and Int(b[j]) != ord(";"):
        var c = Int(b[j])
        var d: Int
        if c >= ord("0") and c <= ord("9"):
            d = c - ord("0")
        elif hex and c >= ord("a") and c <= ord("f"):
            d = c - ord("a") + 10
        elif hex and c >= ord("A") and c <= ord("F"):
            d = c - ord("A") + 10
        else:
            raise _wf("malformed character reference")
        v = min(v * (16 if hex else 10) + d, 0x110000)
        digits += 1
        j += 1
    if j >= end or digits == 0:
        raise _wf("malformed character reference")
    if not _is_char(v):
        raise _wf(String(t"character reference to U+{v}, not a Char"))
    return _Ref(v, j + 1)


def _collapse(s: String) -> String:
    var out = String()
    for word in s.split(" "):
        if word.byte_length() > 0:
            if out.byte_length() > 0:
                out += " "
            out += word
    return out^


# Tokenizes the document into start, end, text and PI events, processing
# the internal subset, entities, attribute defaults and namespaces on the
# way. `src`/`pos` is the input being read: the document, or the
# replacement text of the entity whose reference is being expanded, with
# the outer inputs saved in `frames`.
struct XmlReader(Movable):
    var src: String
    var pos: Int
    var entity: String
    var entry_depth: Int
    var frames: List[_Frame]
    # Entities being expanded, for recursion; parameter entities as "%name".
    var active: List[String]
    var doc_len: Int
    var expanded: Int
    var gents: Dict[String, _Entity]
    var pents: Dict[String, _Entity]
    var attlists: Dict[String, List[_AttDef]]
    var notations: Dict[String, _Notation]
    var doctype_name: String
    var has_doctype: Bool
    var has_external: Bool
    var any_pe_ref: Bool
    var standalone: Bool
    var skip_decls: Bool
    var stack: List[String]
    var ns_prefix: List[String]
    var ns_uri: List[String]
    var ns_marks: List[Int]
    var root_seen: Bool
    var root_done: Bool
    # Produced events not yet consumed, the next one last.
    var pending: List[XEvent]
    # Where text consumed at a depth goes: a struct with an `XmlText` field
    # collects its element's direct character data wherever it is read.
    var sink_depth: List[Int]
    var sink_text: List[String]
    # PIs in the internal subset, reported once the DOCTYPE is read.
    var dtd_pis: List[XEvent]

    def __init__(out self, var text: String) raises DeserializationError:
        self.src = _prepare(text)
        self.doc_len = self.src.byte_length()
        self.pos = 0
        self.entity = String()
        self.entry_depth = 0
        self.frames = []
        self.active = []
        self.expanded = 0
        self.gents = {}
        self.pents = {}
        self.attlists = {}
        self.notations = {}
        self.doctype_name = String()
        self.has_doctype = False
        self.has_external = False
        self.any_pe_ref = False
        self.standalone = False
        self.skip_decls = False
        self.stack = []
        self.ns_prefix = []
        self.ns_uri = []
        self.ns_marks = []
        self.root_seen = False
        self.root_done = False
        self.pending = []
        self.sink_depth = []
        self.sink_text = []
        self.dtd_pis = []
        self._xml_decl()

    # --- low-level scanning of `src` ---------------------------------------

    def _b(self, i: Int) -> Int:
        if i >= self.src.byte_length():
            return -1
        return Int(self.src.as_bytes()[i])

    def _at_end(self) -> Bool:
        return self.pos >= self.src.byte_length()

    def _starts(self, lit: StringSlice) -> Bool:
        var n = lit.byte_length()
        if self.pos + n > self.src.byte_length():
            return False
        var b = self.src.as_bytes()
        var l = lit.as_bytes()
        for k in range(n):
            if b[self.pos + k] != l[k]:
                return False
        return True

    def _find(self, lit: StringSlice) -> Int:
        var n = self.src.byte_length()
        var i = self.pos
        var b = self.src.as_bytes()
        var l = lit.as_bytes()
        while i + len(l) <= n:
            var hit = True
            for k in range(len(l)):
                if b[i + k] != l[k]:
                    hit = False
                    break
            if hit:
                return i
            i += 1
        return -1

    def _text(self, a: Int, b: Int) -> String:
        return _slice(self.src.as_bytes(), a, b)

    def _skip_s(mut self) -> Bool:
        var start = self.pos
        while _is_s(self._b(self.pos)):
            self.pos += 1
        return self.pos > start

    def _req_s(mut self) raises DeserializationError:
        if not self._skip_s():
            raise _wf(String("whitespace required"))

    def _expect(mut self, lit: StringSlice) raises DeserializationError:
        if not self._starts(lit):
            raise _wf(String(t"expected '{lit}'"))
        self.pos += lit.byte_length()

    def _name(mut self) raises DeserializationError -> String:
        var b = self.src.as_bytes()
        var e = _name_end(b, self.pos, len(b))
        if e == self.pos:
            raise _wf(String("expected a name"))
        var n = _slice(b, self.pos, e)
        self.pos = e
        return n^

    def _ncname(mut self) raises DeserializationError -> String:
        var n = self._name()
        if not _is_ncname(n):
            raise _wf(String(t"'{n}' contains a colon"))
        return n^

    # A Name in a DTD declaration, which Namespaces in XML §3 makes a QName.
    def _qname(mut self) raises DeserializationError -> String:
        var n = self._name()
        var at = Int(n.find(":"))
        if at >= 0:
            var b = n.as_bytes()
            if not _is_ncname(_slice(b, 0, at)) or not _is_ncname(
                _slice(b, at + 1, len(b))
            ):
                raise _wf(String(t"'{n}' is not a qualified name"))
        return n^

    def _nmtoken(mut self) raises DeserializationError -> String:
        var b = self.src.as_bytes()
        var e = self.pos
        while e < len(b) and _is_name_char(_cp_at(b, e)):
            e += _utf8_len(Int(b[e]))
        if e == self.pos:
            raise _wf(String("expected a name token"))
        var n = _slice(b, self.pos, e)
        self.pos = e
        return n^

    def _quote(mut self) raises DeserializationError -> Int:
        var q = self._b(self.pos)
        if q != ord('"') and q != ord("'"):
            raise _wf(String("expected a quoted literal"))
        self.pos += 1
        return q

    def _eq(mut self) raises DeserializationError:
        _ = self._skip_s()
        self._expect("=")
        _ = self._skip_s()

    # A keyword that must not run into a following name character.
    def _keyword(mut self, kw: StringSlice) -> Bool:
        if not self._starts(kw):
            return False
        var b = self.src.as_bytes()
        var e = self.pos + kw.byte_length()
        if e < len(b) and _is_name_char(_cp_at(b, e)):
            return False
        self.pos = e
        return True

    # --- the XML declaration -----------------------------------------------

    # Only `<?xml` then whitespace or `?>` is the declaration; a PI such as
    # `<?xml-stylesheet ...?>` is not.
    def _xml_decl(mut self) raises DeserializationError:
        if not self._starts("<?xml"):
            return
        var c = self._b(5)
        if not (_is_s(c) or c == ord("?")):
            return
        self.pos = 5
        self._req_s()
        self._expect("version")
        self._eq()
        var q = self._quote()
        self._expect("1.")
        var digits = 0
        while self._b(self.pos) >= ord("0") and self._b(self.pos) <= ord("9"):
            self.pos += 1
            digits += 1
        if digits == 0 or self._b(self.pos) != q:
            raise _wf(String("malformed version"))
        self.pos += 1
        var had_s = self._skip_s()
        if self._starts("encoding"):
            if not had_s:
                raise _wf(String("whitespace required before encoding"))
            self.pos += 8
            self._eq()
            q = self._quote()
            var c0 = self._b(self.pos)
            if not (
                (c0 >= ord("A") and c0 <= ord("Z"))
                or (c0 >= ord("a") and c0 <= ord("z"))
            ):
                raise _wf(String("malformed encoding name"))
            self.pos += 1
            while True:
                var e = self._b(self.pos)
                if (
                    (e >= ord("A") and e <= ord("Z"))
                    or (e >= ord("a") and e <= ord("z"))
                    or (e >= ord("0") and e <= ord("9"))
                    or e == ord(".")
                    or e == ord("_")
                    or e == ord("-")
                ):
                    self.pos += 1
                else:
                    break
            if self._b(self.pos) != q:
                raise _wf(String("malformed encoding name"))
            self.pos += 1
            had_s = self._skip_s()
        if self._starts("standalone"):
            if not had_s:
                raise _wf(String("whitespace required before standalone"))
            self.pos += 10
            self._eq()
            q = self._quote()
            if self._starts("yes"):
                self.standalone = True
                self.pos += 3
            elif self._starts("no"):
                self.pos += 2
            else:
                raise _wf(String("standalone must be yes or no"))
            if self._b(self.pos) != q:
                raise _wf(String("malformed standalone"))
            self.pos += 1
            _ = self._skip_s()
        self._expect("?>")

    # --- entities ----------------------------------------------------------

    def _count(mut self, n: Int) raises DeserializationError:
        self.expanded += n
        var total = self.doc_len + self.expanded
        if total >= 8388608 and total > 100 * max(1, self.doc_len):
            raise _wf(
                String("entity expansion exceeds the amplification limit")
            )

    def _push(
        mut self, var text: String, var name: String
    ) raises DeserializationError:
        self._count(text.byte_length())
        swap(self.src, text)
        var entity = name.copy()
        swap(self.entity, entity)
        self.frames.append(_Frame(text^, self.pos, entity^, self.entry_depth))
        self.pos = 0
        self.entry_depth = len(self.stack)
        self.active.append(name^)

    def _pop(mut self):
        var f = self.frames.pop()
        swap(self.src, f.src)
        swap(self.entity, f.entity)
        self.pos = f.pos
        self.entry_depth = f.depth
        _ = self.active.pop()

    # Whether an undeclared entity is a well-formedness error (§4.1, WFC:
    # Entity Declared); otherwise its declaration may be in what wasn't read.
    def _entity_wfc(self) -> Bool:
        return (
            not self.has_doctype
            or (not self.has_external and not self.any_pe_ref)
            or self.standalone
        )

    def _undeclared(self, name: String) -> DeserializationError:
        if self._entity_wfc():
            return _wf(String(t"undeclared entity &{name};"))
        return _unsupported(
            String(t"&{name}; may be declared in a DTD part that isn't read")
        )

    # A reference in content: its text, or nothing after pushing an
    # entity's replacement text.
    def _content_ref(mut self) raises DeserializationError -> Optional[String]:
        var n = self.src.byte_length()
        if self._b(self.pos + 1) == ord("#"):
            var r = _char_ref(self.src.as_bytes(), self.pos + 2, n)
            self.pos = r.next
            return _cp_string(r.cp)
        var ne = _name_end(self.src.as_bytes(), self.pos + 1, n)
        if ne == self.pos + 1 or self._b(ne) != ord(";"):
            raise _wf(String("'&' that doesn't start a reference"))
        var name = self._text(self.pos + 1, ne)
        _check_ref_name(name)
        self.pos = ne + 1
        var p = _predefined(name)
        if p:
            return p
        var e = self.gents.get(name)
        if not e:
            raise self._undeclared(name)
        var ent = e.value().copy()
        if ent.unparsed:
            raise _wf(String(t"reference to the unparsed entity &{name};"))
        if ent.external:
            raise _unsupported(String(t"external entity &{name}; isn't read"))
        if name in self.active:
            raise _wf(String(t"entity &{name}; refers to itself"))
        self._push(ent.value.copy(), name^)
        return None

    # Appends a referenced entity's replacement text, normalized as part of
    # an attribute value (§3.3.3).
    def _att_entity(
        mut self, mut out: String, name: String
    ) raises DeserializationError:
        var p = _predefined(name)
        if p:
            out += p.value()
            return
        var e = self.gents.get(name)
        if not e:
            raise self._undeclared(name)
        var ent = e.value().copy()
        if ent.external or ent.unparsed:
            raise _wf(
                String(
                    t"attribute value refers to the external entity &{name};"
                )
            )
        if name in self.active:
            raise _wf(String(t"entity &{name}; refers to itself"))
        self._count(ent.value.byte_length())
        self.active.append(name.copy())
        self._att_text(out, ent.value)
        _ = self.active.pop()

    def _att_text(
        mut self, mut out: String, text: String
    ) raises DeserializationError:
        var b = text.as_bytes()
        var n = len(b)
        var i = 0
        while i < n:
            var c = Int(b[i])
            if c == ord("<"):
                raise _wf(String("'<' in an attribute value"))
            if c == ord("&"):
                if i + 1 < n and Int(b[i + 1]) == ord("#"):
                    var r = _char_ref(b, i + 2, n)
                    out += _cp_string(r.cp)
                    i = r.next
                    continue
                var ne = _name_end(b, i + 1, n)
                if ne == i + 1 or ne >= n or Int(b[ne]) != ord(";"):
                    raise _wf(String("'&' that doesn't start a reference"))
                var nm = _slice(b, i + 1, ne)
                _check_ref_name(nm)
                i = ne + 1
                self._att_entity(out, nm)
                continue
            if _is_s(c):
                out += " "
                i += 1
                continue
            var l = _utf8_len(c)
            out += StringSlice(unsafe_from_utf8=b[i : i + l])
            i += l

    # An attribute value literal, normalized with its references expanded;
    # with `expand` off it is only checked.
    def _att_value(
        mut self, expand: Bool = True
    ) raises DeserializationError -> String:
        var q = self._quote()
        var out = String()
        while True:
            if self._at_end():
                raise _wf(String("unterminated attribute value"))
            var c = self._b(self.pos)
            if c == q:
                self.pos += 1
                return out^
            if c == ord("<"):
                raise _wf(String("'<' in an attribute value"))
            if c == ord("&"):
                var n = self.src.byte_length()
                if self._b(self.pos + 1) == ord("#"):
                    var r = _char_ref(self.src.as_bytes(), self.pos + 2, n)
                    out += _cp_string(r.cp)
                    self.pos = r.next
                    continue
                var ne = _name_end(self.src.as_bytes(), self.pos + 1, n)
                if ne == self.pos + 1 or self._b(ne) != ord(";"):
                    raise _wf(String("'&' that doesn't start a reference"))
                var name = self._text(self.pos + 1, ne)
                _check_ref_name(name)
                self.pos = ne + 1
                if expand:
                    self._att_entity(out, name)
                continue
            if _is_s(c):
                out += " "
                self.pos += 1
                continue
            var l = _utf8_len(c)
            out += self._text(self.pos, self.pos + l)
            self.pos += l

    # --- the DTD -----------------------------------------------------------

    def _doctype(mut self) raises DeserializationError:
        self.pos += 9
        self._req_s()
        self.doctype_name = self._qname()
        var had_s = self._skip_s()
        if self._starts("SYSTEM") or self._starts("PUBLIC"):
            if not had_s:
                raise _wf(String("whitespace required before the external ID"))
            _ = self._external_id(False)
            self.has_external = True
            _ = self._skip_s()
        if self._b(self.pos) == ord("["):
            self.pos += 1
            self._decls(False)
            self._expect("]")
            _ = self._skip_s()
        self._expect(">")
        self.has_doctype = True

    def _system_literal(mut self) raises DeserializationError -> String:
        var q = self._quote()
        var start = self.pos
        while self._b(self.pos) != q:
            if self._at_end():
                raise _wf(String("unterminated system literal"))
            self.pos += 1
        var s = self._text(start, self.pos)
        self.pos += 1
        return s^

    def _pubid_literal(mut self) raises DeserializationError -> String:
        var q = self._quote()
        var start = self.pos
        while self._b(self.pos) != q:
            var c = self._b(self.pos)
            if c == -1 or not _is_pubid_char(c):
                raise _wf(String("invalid character in a public ID"))
            self.pos += 1
        # Whitespace runs collapse to one space, trimmed (§4.2.2).
        var s = self._text(start, self.pos)
        self.pos += 1
        return _collapse(s.replace("\n", " ").replace("\r", " "))

    # `SYSTEM lit` or `PUBLIC pub lit`; a notation may be `PUBLIC pub` alone.
    def _external_id(
        mut self, public_alone: Bool
    ) raises DeserializationError -> _Notation:
        if self._keyword("SYSTEM"):
            self._req_s()
            return _Notation(None, self._system_literal())
        if not self._keyword("PUBLIC"):
            raise _wf(String("expected SYSTEM or PUBLIC"))
        self._req_s()
        var pub = self._pubid_literal()
        if public_alone:
            var save = self.pos
            var had_s = self._skip_s()
            var c = self._b(self.pos)
            if not had_s or (c != ord('"') and c != ord("'")):
                self.pos = save
                return _Notation(pub^, None)
        else:
            self._req_s()
        return _Notation(pub^, self._system_literal())

    # Markup declarations up to `]` (the internal subset) or the end of a
    # parameter entity's replacement text.
    def _decls(mut self, in_pe: Bool) raises DeserializationError:
        while True:
            _ = self._skip_s()
            if self._at_end():
                if in_pe:
                    return
                raise _wf(String("unterminated DOCTYPE"))
            var c = self._b(self.pos)
            if c == ord("]") and not in_pe:
                return
            if c == ord("%"):
                self._pe_between_decls()
            elif self._starts("<!ELEMENT"):
                self._element_decl()
            elif self._starts("<!ATTLIST"):
                self._attlist_decl()
            elif self._starts("<!ENTITY"):
                self._entity_decl()
            elif self._starts("<!NOTATION"):
                self._notation_decl()
            elif self._starts("<!--"):
                self._comment()
            elif self._starts("<?"):
                self.dtd_pis.append(self._pi())
            else:
                raise _wf(String("invalid markup in the internal subset"))

    def _pe_between_decls(mut self) raises DeserializationError:
        self.pos += 1
        var name = self._ncname()
        self._expect(";")
        var e = self.pents.get(name)
        self.any_pe_ref = True
        if not e:
            if self.standalone:
                raise _wf(String(t"undeclared parameter entity %{name};"))
            self.skip_decls = True
            return
        var ent = e.value().copy()
        if ent.external:
            # Not read, so later declarations may be overridden by it (§5.1).
            if not self.standalone:
                self.skip_decls = True
            return
        var key = "%" + name
        if key in self.active:
            raise _wf(String(t"parameter entity %{name}; refers to itself"))
        self._push(ent.value.copy(), key^)
        self._decls(True)
        self._pop()

    def _element_decl(mut self) raises DeserializationError:
        self.pos += 9
        self._req_s()
        _ = self._qname()
        self._req_s()
        if not (self._keyword("EMPTY") or self._keyword("ANY")):
            if self._b(self.pos) != ord("("):
                raise _wf(String("malformed content model"))
            self.pos += 1
            _ = self._skip_s()
            if self._starts("#PCDATA"):
                self.pos += 7
                _ = self._skip_s()
                if self._b(self.pos) == ord(")"):
                    self.pos += 1
                    if self._b(self.pos) == ord("*"):
                        self.pos += 1
                else:
                    while self._b(self.pos) == ord("|"):
                        self.pos += 1
                        _ = self._skip_s()
                        _ = self._qname()
                        _ = self._skip_s()
                    self._expect(")*")
            else:
                self._group_rest()
                self._occurrence()
        _ = self._skip_s()
        self._expect(">")

    def _occurrence(mut self):
        var c = self._b(self.pos)
        if c == ord("?") or c == ord("*") or c == ord("+"):
            self.pos += 1

    def _cp(mut self) raises DeserializationError:
        if self._b(self.pos) == ord("("):
            self.pos += 1
            _ = self._skip_s()
            self._group_rest()
        else:
            _ = self._qname()
        self._occurrence()

    # A choice or seq after its '(' and leading whitespace, through ')'.
    def _group_rest(mut self) raises DeserializationError:
        self._cp()
        var sep = -1
        while True:
            _ = self._skip_s()
            var c = self._b(self.pos)
            if c == ord(")"):
                self.pos += 1
                return
            if c != ord("|") and c != ord(","):
                raise _wf(String("malformed content model"))
            if sep != -1 and c != sep:
                raise _wf(String("mixed separators in a content model"))
            sep = c
            self.pos += 1
            _ = self._skip_s()
            self._cp()

    def _attlist_decl(mut self) raises DeserializationError:
        self.pos += 9
        self._req_s()
        var elem = self._qname()
        while True:
            var had_s = self._skip_s()
            if self._b(self.pos) == ord(">"):
                self.pos += 1
                return
            if not had_s:
                raise _wf(String("whitespace required in ATTLIST"))
            var name = self._qname()
            self._req_s()
            var tokenized = True
            if self._keyword("CDATA"):
                tokenized = False
            elif (
                self._keyword("IDREFS")
                or self._keyword("IDREF")
                or self._keyword("ID")
                or self._keyword("ENTITIES")
                or self._keyword("ENTITY")
                or self._keyword("NMTOKENS")
                or self._keyword("NMTOKEN")
            ):
                pass
            elif self._keyword("NOTATION"):
                self._req_s()
                self._expect("(")
                _ = self._skip_s()
                _ = self._ncname()
                _ = self._skip_s()
                while self._b(self.pos) == ord("|"):
                    self.pos += 1
                    _ = self._skip_s()
                    _ = self._ncname()
                    _ = self._skip_s()
                self._expect(")")
            elif self._b(self.pos) == ord("("):
                self.pos += 1
                _ = self._skip_s()
                _ = self._nmtoken()
                _ = self._skip_s()
                while self._b(self.pos) == ord("|"):
                    self.pos += 1
                    _ = self._skip_s()
                    _ = self._nmtoken()
                    _ = self._skip_s()
                self._expect(")")
            else:
                raise _wf(String("unknown attribute type"))
            self._req_s()
            var default = Optional[String]()
            if self._keyword("#REQUIRED") or self._keyword("#IMPLIED"):
                pass
            else:
                if self._keyword("#FIXED"):
                    self._req_s()
                var v = self._att_value(not self.skip_decls)
                if tokenized:
                    v = _collapse(v)
                default = v^
            if self.skip_decls:
                continue
            if elem not in self.attlists:
                self.attlists[elem] = []
            try:
                ref defs = self.attlists[elem]
                var seen = False
                for d in defs:
                    if d.name == name:
                        seen = True
                if not seen:
                    defs.append(_AttDef(name^, tokenized, default^))
            except:
                pass

    def _entity_decl(mut self) raises DeserializationError:
        self.pos += 8
        self._req_s()
        var pe = False
        if self._b(self.pos) == ord("%"):
            self.pos += 1
            self._req_s()
            pe = True
        var name = self._ncname()
        self._req_s()
        var ent: _Entity
        var c = self._b(self.pos)
        if c == ord('"') or c == ord("'"):
            ent = _Entity(self._entity_value(), False, False)
        else:
            _ = self._external_id(False)
            var unparsed = False
            if not pe:
                var save = self.pos
                var had_s = self._skip_s()
                if self._keyword("NDATA"):
                    if not had_s:
                        raise _wf(String("whitespace required before NDATA"))
                    self._req_s()
                    _ = self._ncname()
                    unparsed = True
                else:
                    self.pos = save
            ent = _Entity(String(), True, unparsed)
        _ = self._skip_s()
        self._expect(">")
        if self.skip_decls:
            return
        if pe:
            if name not in self.pents:
                self.pents[name] = ent^
        elif name not in self.gents:
            self.gents[name] = ent^

    # The replacement text of an internal entity: character references
    # expanded, entity references kept for when it is used (§4.5).
    def _entity_value(mut self) raises DeserializationError -> String:
        var q = self._quote()
        var out = String()
        while True:
            if self._at_end():
                raise _wf(String("unterminated entity value"))
            var c = self._b(self.pos)
            if c == q:
                self.pos += 1
                return out^
            if c == ord("%"):
                raise _wf(
                    String("parameter-entity reference in the internal subset")
                )
            if c == ord("&"):
                var n = self.src.byte_length()
                if self._b(self.pos + 1) == ord("#"):
                    var r = _char_ref(self.src.as_bytes(), self.pos + 2, n)
                    out += _cp_string(r.cp)
                    self.pos = r.next
                    continue
                var ne = _name_end(self.src.as_bytes(), self.pos + 1, n)
                if ne == self.pos + 1 or self._b(ne) != ord(";"):
                    raise _wf(String("'&' that doesn't start a reference"))
                _check_ref_name(self._text(self.pos + 1, ne))
                out += self._text(self.pos, ne + 1)
                self.pos = ne + 1
                continue
            var l = _utf8_len(c)
            out += self._text(self.pos, self.pos + l)
            self.pos += l

    def _notation_decl(mut self) raises DeserializationError:
        self.pos += 10
        self._req_s()
        var name = self._ncname()
        self._req_s()
        var id = self._external_id(True)
        _ = self._skip_s()
        self._expect(">")
        if name not in self.notations:
            self.notations[name] = id^

    # --- markup ------------------------------------------------------------

    def _comment(mut self) raises DeserializationError:
        self.pos += 4
        var at = self._find("--")
        if at < 0:
            raise _wf(String("unterminated comment"))
        if self._b(at + 2) != ord(">"):
            raise _wf(String("'--' in a comment"))
        self.pos = at + 3

    def _pi(mut self) raises DeserializationError -> XEvent:
        self.pos += 2
        var target = self._name()
        if target.lower() == "xml":
            raise _wf(String("the target 'xml' is reserved"))
        if not _is_ncname(target):
            raise _wf(String(t"PI target '{target}' contains a colon"))
        var data = String()
        if self._starts("?>"):
            self.pos += 2
        else:
            if not self._skip_s():
                raise _wf(String("whitespace required after a PI target"))
            var at = self._find("?>")
            if at < 0:
                raise _wf(String("unterminated processing instruction"))
            data = self._text(self.pos, at)
            self.pos = at + 2
        var ev = _event(_PI, len(self.stack), data^)
        ev.qname = target^
        return ev^

    def _lookup(self, prefix: String) raises DeserializationError -> String:
        if prefix == "xml":
            return String(XML_NS)
        var i = len(self.ns_prefix) - 1
        while i >= 0:
            if self.ns_prefix[i] == prefix:
                return self.ns_uri[i].copy()
            i -= 1
        if prefix == "":
            return String()
        raise _wf(String(t"unbound namespace prefix '{prefix}'"))

    # A QName's prefix and local part.
    def _split(
        self, qname: String
    ) raises DeserializationError -> Tuple[String, String]:
        var at = Int(qname.find(":"))
        if at < 0:
            return (String(), qname.copy())
        var b = qname.as_bytes()
        var prefix = _slice(b, 0, at)
        var local = _slice(b, at + 1, len(b))
        if not _is_ncname(prefix) or not _is_ncname(local):
            raise _wf(String(t"'{qname}' is not a qualified name"))
        if prefix == "xmlns":
            raise _wf(String(t"'{qname}' uses the reserved prefix xmlns"))
        return (prefix^, local^)

    def _bind(mut self, mut attrs: List[XAttr]) raises DeserializationError:
        self.ns_marks.append(len(self.ns_prefix))
        for ref a in attrs:
            if a.qname == "xmlns":
                if a.value == XML_NS or a.value == XMLNS_NS:
                    raise _wf(
                        String("default namespace bound to a reserved URI")
                    )
                self.ns_prefix.append(String())
                self.ns_uri.append(a.value.copy())
                a.uri = String(XMLNS_NS)
                a.local = String("xmlns")
            elif a.qname.startswith("xmlns:"):
                var p = _slice(a.qname.as_bytes(), 6, a.qname.byte_length())
                if not _is_ncname(p) or p == "xmlns":
                    raise _wf(String(t"can't declare the prefix '{p}'"))
                if p == "xml":
                    if a.value != XML_NS:
                        raise _wf(String("xml bound to another namespace"))
                else:
                    if a.value == XML_NS or a.value == XMLNS_NS:
                        raise _wf(String(t"'{p}' bound to a reserved URI"))
                    if a.value == "":
                        raise _wf(String(t"can't undeclare the prefix '{p}'"))
                    self.ns_prefix.append(p.copy())
                    self.ns_uri.append(a.value.copy())
                a.uri = String(XMLNS_NS)
                a.local = p^
        for ref a in attrs:
            if a.uri == XMLNS_NS:
                continue
            var parts = self._split(a.qname)
            if parts[0] == "":
                a.local = parts[1].copy()
            else:
                a.uri = self._lookup(parts[0])
                a.local = parts[1].copy()
        for i in range(len(attrs)):
            for j in range(i + 1, len(attrs)):
                if (
                    attrs[i].uri != ""
                    and attrs[i].uri == attrs[j].uri
                    and attrs[i].local == attrs[j].local
                ):
                    raise _wf(
                        String(
                            t"attributes {attrs[i].qname} and"
                            t" {attrs[j].qname} have the same expanded name"
                        )
                    )

    def _resolve(self, qname: String) raises DeserializationError -> XEvent:
        var parts = self._split(qname)
        var ev = _event(_START, 0)
        ev.qname = qname.copy()
        ev.uri = self._lookup(parts[0])
        ev.local = parts[1].copy()
        return ev^

    def _start_tag(mut self, mut out: List[XEvent]) raises DeserializationError:
        if self.root_done:
            raise _wf(String("content after the root element"))
        self.pos += 1
        var name = self._name()
        var attrs = List[XAttr]()
        var empty = False
        while True:
            var had_s = self._skip_s()
            if self._starts("/>"):
                self.pos += 2
                empty = True
                break
            if self._b(self.pos) == ord(">"):
                self.pos += 1
                break
            if self._at_end():
                raise _wf(String("unterminated start tag"))
            if not had_s:
                raise _wf(String("attributes must be separated by whitespace"))
            var an = self._name()
            self._eq()
            var v = self._att_value()
            for a in attrs:
                if a.qname == an:
                    raise _wf(String(t"duplicate attribute {an}"))
            attrs.append(XAttr(an^, String(), String(), v^))
        var defs = self.attlists.get(name)
        if defs:
            for d in defs.value():
                var found = False
                for ref a in attrs:
                    if a.qname == d.name:
                        found = True
                        if d.tokenized:
                            a.value = _collapse(a.value)
                if not found and d.default:
                    attrs.append(
                        XAttr(
                            d.name.copy(),
                            String(),
                            String(),
                            d.default.value().copy(),
                        )
                    )
        var depth = len(self.stack)
        self._bind(attrs)
        var ev = self._resolve(name)
        ev.depth = depth
        ev.attrs = attrs^
        self.stack.append(name^)
        self.root_seen = True
        out.append(ev^)
        if empty:
            self._close(out)

    def _close(mut self, mut out: List[XEvent]) raises DeserializationError:
        var ev = self._resolve(self.stack[len(self.stack) - 1])
        ev.kind = _END
        ev.depth = len(self.stack) - 1
        out.append(ev^)
        _ = self.stack.pop()
        var mark = self.ns_marks.pop()
        while len(self.ns_prefix) > mark:
            _ = self.ns_prefix.pop()
            _ = self.ns_uri.pop()
        if not self.stack:
            self.root_done = True

    def _end_tag(mut self, mut out: List[XEvent]) raises DeserializationError:
        self.pos += 2
        var name = self._name()
        _ = self._skip_s()
        self._expect(">")
        if not self.stack:
            raise _wf(String(t"end tag </{name}> without a start tag"))
        if len(self.stack) <= self.entry_depth:
            raise _wf(String(t"</{name}> closes an element outside its entity"))
        if self.stack[len(self.stack) - 1] != name:
            raise _wf(
                String(
                    t"</{name}> doesn't match"
                    t" <{self.stack[len(self.stack) - 1]}>"
                )
            )
        self._close(out)

    # The next event(s) into `out`.
    def _produce(mut self, mut out: List[XEvent]) raises DeserializationError:
        while True:
            if self._at_end():
                if self.frames:
                    if len(self.stack) != self.entry_depth:
                        raise _wf(
                            String(t"entity &{self.entity}; is not balanced")
                        )
                    self._pop()
                    continue
                if self.stack:
                    raise _wf(
                        String(
                            t"unterminated <{self.stack[len(self.stack) - 1]}>"
                        )
                    )
                if not self.root_seen:
                    raise _wf(String("no root element"))
                out.append(_event(_EOF, 0))
                return
            var c = self._b(self.pos)
            if c == ord("<"):
                if self._starts("</"):
                    self._end_tag(out)
                    return
                if self._starts("<!--"):
                    self._comment()
                    continue
                if self._starts("<![CDATA["):
                    if not self.stack:
                        raise _wf(String("CDATA section outside the root"))
                    self.pos += 9
                    var at = self._find("]]>")
                    if at < 0:
                        raise _wf(String("unterminated CDATA section"))
                    out.append(
                        _event(
                            _TEXT_EV, len(self.stack), self._text(self.pos, at)
                        )
                    )
                    self.pos = at + 3
                    return
                if self._starts("<?"):
                    out.append(self._pi())
                    return
                if self._starts("<!DOCTYPE"):
                    if self.frames or self.root_seen or self.has_doctype:
                        raise _wf(String("misplaced DOCTYPE"))
                    self._doctype()
                    if self.dtd_pis:
                        for ev in self.dtd_pis:
                            out.append(ev.copy())
                        self.dtd_pis = []
                        return
                    continue
                if self._b(self.pos + 1) == ord("!"):
                    raise _wf(String("invalid markup"))
                self._start_tag(out)
                return
            if c == ord("&"):
                if not self.stack:
                    raise _wf(String("reference outside the root element"))
                var t = self._content_ref()
                if t:
                    out.append(_event(_TEXT_EV, len(self.stack), t.value()))
                    return
                continue
            var start = self.pos
            var n = self.src.byte_length()
            while self.pos < n:
                var d = self._b(self.pos)
                if d == ord("<") or d == ord("&"):
                    break
                if (
                    d == ord(">")
                    and self.pos - start >= 2
                    and self._b(self.pos - 1) == ord("]")
                    and self._b(self.pos - 2) == ord("]")
                ):
                    raise _wf(String("']]>' in character data"))
                self.pos += 1
            if not self.stack:
                for k in range(start, self.pos):
                    if not _is_s(self._b(k)):
                        raise _wf(String("text outside the root element"))
                continue
            out.append(
                _event(_TEXT_EV, len(self.stack), self._text(start, self.pos))
            )
            return

    # --- what the deserializer reads ---------------------------------------

    def _fill(mut self) raises DeserializationError:
        if self.pending:
            return
        var out = List[XEvent]()
        self._produce(out)
        while out:
            self.pending.append(out.pop())

    def peek(mut self) raises DeserializationError -> XEvent:
        self._fill()
        return self.pending[len(self.pending) - 1].copy()

    def peek_kind(mut self) raises DeserializationError -> Int:
        self._fill()
        return self.pending[len(self.pending) - 1].kind

    def next(mut self) raises DeserializationError -> XEvent:
        self._fill()
        var ev = self.pending.pop()
        if (
            ev.kind == _TEXT_EV
            and self.sink_depth
            and self.sink_depth[len(self.sink_depth) - 1] == ev.depth
        ):
            self.sink_text[len(self.sink_text) - 1] += ev.text
        return ev^

    def push_sink(mut self, depth: Int):
        self.sink_depth.append(depth)
        self.sink_text.append(String())

    def pop_sink(mut self) -> String:
        _ = self.sink_depth.pop()
        return self.sink_text.pop()

    # Past text and PIs: what separates siblings.
    def skip_misc(mut self) raises DeserializationError:
        while True:
            var k = self.peek_kind()
            if k != _TEXT_EV and k != _PI:
                return
            _ = self.next()

    def start_element(mut self) raises DeserializationError -> XEvent:
        self.skip_misc()
        var ev = self.next()
        if ev.kind != _START:
            raise _invalid(String("expected an element"))
        return ev^

    def expect_end(mut self) raises DeserializationError:
        self.skip_misc()
        if self.next().kind != _END:
            raise _invalid(String("expected an end tag"))

    def skip_element(mut self) raises DeserializationError:
        _ = self.start_element()
        var depth = 1
        while depth > 0:
            var k = self.next().kind
            if k == _START:
                depth += 1
            elif k == _END:
                depth -= 1

    # The element's events, taken out of the stream to be put back later.
    def record_element(mut self) raises DeserializationError -> List[XEvent]:
        self.skip_misc()
        var out = List[XEvent]()
        var depth = 0
        while True:
            self._fill()
            var ev = self.pending.pop()
            if ev.kind == _START:
                depth += 1
            elif ev.kind == _END:
                depth -= 1
            out.append(ev^)
            if depth == 0:
                return out^

    def push_back(mut self, var events: List[XEvent]):
        while events:
            self.pending.append(events.pop())

    # Consumes the leaf element here and returns its text.
    def leaf(mut self) raises DeserializationError -> String:
        _ = self.start_element()
        var out = String()
        while True:
            var ev = self.next()
            if ev.kind == _TEXT_EV:
                out += ev.text
            elif ev.kind == _START:
                raise _mismatch(String("expected text, found an element"))
            elif ev.kind == _END:
                return out^


# ----------------------------------------------------------------------------
# Deserialization
# ----------------------------------------------------------------------------


def _attr_of(ev: XEvent, local: StringSlice) -> Optional[String]:
    for a in ev.attrs:
        if a.uri == "" and a.local == local:
            return a.value.copy()
    return None


def _unknown(name: String) -> DeserializationError:
    return DeserializationError(
        String(t"Unknown field: {name}"), DerErrorKind.UnknownField
    )


# The field of `T` an attribute (`attr`) or child element binds, or -1.
def _match[T: AnyType](uri: String, local: String, attr: Bool) -> Int:
    comptime for i in range(reflect[T].field_count()):
        comptime if count_annotations[T, i, XmlText]() == 0:
            if name_matches[T, i](local):
                var ns = _attr_ns[T, i]() if attr else _elem_ns[T, i]()
                if ns == uri:
                    return i
    return -1


# A list field's run of same-named siblings (`run_local` set), or a boxed
# list's children.
@fieldwise_init
struct XmlSeqDe[origin: MutOrigin](SeqDerState):
    var cur: Pointer[XmlReader, Self.origin]
    var run_uri: String
    var run_local: String
    var first: Bool
    var empty: Bool
    # An `XmlMixed` field: every text run and child element, in order, up
    # to the end tag (which the struct consumes); `run_uri` is the
    # namespace its elements are in.
    var mixed: Bool

    def has_next(mut self) raises DeserializationError -> Bool:
        if self.empty:
            return False
        ref r = self.cur[]
        if self.mixed:
            while r.peek_kind() == _PI:
                _ = r.next()
            var k = r.peek_kind()
            return k == _TEXT_EV or k == _START
        r.skip_misc()
        var ev = r.peek()
        if self.run_local:
            if self.first:
                self.first = False
                return True
            # Only a same-named sibling continues the run; anything else
            # belongs to the parent.
            return (
                ev.kind == _START
                and ev.uri == self.run_uri
                and ev.local == self.run_local
            )
        return ev.kind == _START

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        if self.mixed:
            ref r = self.cur[]
            # A run is all the text up to the next element or end tag;
            # comments and PIs inside it don't split it.
            var text = String()
            var is_text = r.peek_kind() == _TEXT_EV
            while is_text and (
                r.peek_kind() == _TEXT_EV or r.peek_kind() == _PI
            ):
                var ev = r.next()
                if ev.kind == _TEXT_EV:
                    text += ev.text
            var part = XmlDe(
                cur=self.cur,
                mode=_TEXT_PART if is_text else _PART,
                name="item",
                text=text^,
                payload=False,
                uri=self.run_uri.copy(),
            )
            return deserialize[T](part)
        var sub = XmlDe(
            cur=self.cur,
            mode=_ELEMENT,
            name="item",
            text=String(),
            payload=False,
            uri=String(),
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        if self.empty or self.run_local or self.mixed:
            return
        self.cur[].expect_end()


# Entries are a map field's run of same-named siblings, or a boxed map's
# children; each holds a `key` and a `value`, in either order. A value met
# first is held aside until the key has been read.
@fieldwise_init
struct XmlMapDe[origin: MutOrigin](MapDerState):
    var cur: Pointer[XmlReader, Self.origin]
    var run_uri: String
    var run_local: String
    var first: Bool
    var empty: Bool
    var in_entry: Bool
    var got_key: Bool
    var got_value: Bool
    var held: List[XEvent]

    def _finish_entry(mut self) raises DeserializationError:
        if not self.in_entry:
            return
        ref r = self.cur[]
        while True:
            r.skip_misc()
            var ev = r.peek()
            if ev.kind == _END:
                _ = r.next()
                break
            if (ev.local == "key" and self.got_key) or (
                ev.local == "value" and self.got_value
            ):
                raise DeserializationError(
                    String(t"duplicate field: {ev.local}"),
                    DerErrorKind.DuplicateField,
                )
            r.skip_element()
        self.in_entry = False

    def has_next(mut self) raises DeserializationError -> Bool:
        self._finish_entry()
        if self.empty:
            return False
        ref r = self.cur[]
        r.skip_misc()
        var ev = r.peek()
        if self.run_local:
            if self.first:
                self.first = False
                return True
            return (
                ev.kind == _START
                and ev.uri == self.run_uri
                and ev.local == self.run_local
            )
        return ev.kind == _START

    # Scans the entry's children for `name`, holding a `value` met on the
    # way to the key; the view reads it, or is empty when there is none.
    def _part(
        mut self, name: StaticString
    ) raises DeserializationError -> XmlDe[Self.origin]:
        ref r = self.cur[]
        while True:
            r.skip_misc()
            var ev = r.peek()
            if ev.kind != _START:
                return XmlDe(
                    cur=self.cur,
                    mode=_EMPTY,
                    name=name,
                    text=String(),
                    payload=False,
                    uri=String(),
                )
            if ev.local == name:
                return XmlDe(
                    cur=self.cur,
                    mode=_FIELD,
                    name=name,
                    text=String(),
                    payload=False,
                    uri=String(),
                )
            if ev.local == "value" and not self.got_value and not self.held:
                self.held = r.record_element()
                continue
            if ev.local == "key" or ev.local == "value":
                raise DeserializationError(
                    String(t"duplicate field: {ev.local}"),
                    DerErrorKind.DuplicateField,
                )
            r.skip_element()

    def expect_key[T: AnyType](mut self) raises DeserializationError -> T:
        _ = self.cur[].start_element()
        self.in_entry = True
        self.got_key = True
        self.got_value = False
        self.held = []
        var sub = self._part("key")
        return deserialize[T](sub)

    def expect_value[T: AnyType](mut self) raises DeserializationError -> T:
        self.got_value = True
        if self.held:
            var held = List[XEvent]()
            swap(held, self.held)
            self.cur[].push_back(held^)
        var sub = self._part("value")
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        self._finish_entry()
        if self.empty or self.run_local:
            return
        self.cur[].expect_end()


# An attribute that binds field `field`.
@fieldwise_init
struct _FieldAttr(Copyable, Movable):
    var field: Int
    var value: String


# Yields the attribute fields, then each child as the reader reaches it,
# then the text field once the end tag is in front, then every absent field
# the framework won't fill. A field met again later (an interleaved list) is
# simply yielded again.
@fieldwise_init
struct XmlStructDe[origin: MutOrigin](StructDerState):
    var cur: Pointer[XmlReader, Self.origin]
    var attrs: List[_FieldAttr]
    var names: List[StaticString]
    var serve_absent: List[Bool]
    var yielded: List[Bool]
    var text_field: Int
    # The `XmlMixed` field, which takes all the children and text, and the
    # namespace its elements are in.
    var mixed_field: Int
    var mixed_ns: String
    var deny_unknown: Bool
    # 0: attributes, 1: children, 2: text, 3: absent fields.
    var phase: Int
    var next: Int
    # The field just yielded, and how its value is read.
    var current: Int
    var mode: Int
    var value: String

    def _serve(mut self, i: Int, mode: Int) -> Int:
        self.yielded[i] = True
        self.current = i
        self.mode = mode
        return i

    def expect_field_index[
        T: AnyType
    ](mut self) raises DeserializationError -> Optional[Int]:
        ref r = self.cur[]
        while True:
            if self.phase == 0:
                if self.next < len(self.attrs):
                    var a = self.attrs[self.next].copy()
                    self.next += 1
                    self.value = a.value.copy()
                    return self._serve(a.field, _ATTR)
                self.phase = 1
            elif self.phase == 1:
                if self.mixed_field >= 0:
                    self.phase = 2
                    return self._serve(self.mixed_field, _MIXED)
                r.skip_misc()
                var ev = r.peek()
                if ev.kind == _END:
                    self.phase = 2
                    continue
                var i = _match[T](ev.uri, ev.local, False)
                if i < 0:
                    if self.deny_unknown:
                        raise _unknown(ev.qname)
                    r.skip_element()
                    continue
                return self._serve(i, _FIELD)
            elif self.phase == 2:
                self.phase = 3
                self.next = 0
                var t = self.text_field
                if t >= 0:
                    var text = r.pop_sink()
                    if not self.yielded[t] and (text or self.serve_absent[t]):
                        self.value = text^
                        return self._serve(t, _TEXT)
            else:
                while self.next < len(self.yielded):
                    var i = self.next
                    self.next += 1
                    if not self.yielded[i] and self.serve_absent[i]:
                        return self._serve(i, _EMPTY)
                return None

    def expect_field_value[
        T: AnyType
    ](mut self) raises DeserializationError -> T:
        var sub = XmlDe(
            cur=self.cur,
            mode=self.mode,
            name=self.names[self.current],
            text=self.value.copy(),
            payload=False,
            uri=self.mixed_ns.copy(),
        )
        return deserialize[T](sub)

    def skip_value(mut self) raises DeserializationError:
        if self.mode == _FIELD:
            self.cur[].skip_element()

    def end(mut self) raises DeserializationError:
        self.cur[].expect_end()


@fieldwise_init
struct XmlTupleDe[origin: MutOrigin](TupleDerState):
    var cur: Pointer[XmlReader, Self.origin]

    def expect_element[T: AnyType](mut self) raises DeserializationError -> T:
        ref r = self.cur[]
        r.skip_misc()
        if r.peek_kind() != _START:
            raise _invalid(String("tuple has too few elements"))
        var sub = XmlDe(
            cur=self.cur,
            mode=_ELEMENT,
            name="item",
            text=String(),
            payload=False,
            uri=String(),
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        ref r = self.cur[]
        r.skip_misc()
        if r.peek_kind() == _START:
            raise _invalid(String("tuple has too many elements"))
        r.expect_end()


# The payload shares the variant's element, which `begin_enum` only peeked.
@fieldwise_init
struct XmlEnumDe[origin: MutOrigin](EnumDerState):
    var cur: Pointer[XmlReader, Self.origin]
    var idx: Int
    var name: StaticString
    # Mixed content: the run of text the payload is, or (an element part)
    # an element named by its arm rather than carrying a `variant` tag.
    var text: Optional[String]
    var payload: Bool

    def variant_index(mut self) raises DeserializationError -> Int:
        return self.idx

    def expect_payload[T: AnyType](mut self) raises DeserializationError -> T:
        var sub = XmlDe(
            cur=self.cur,
            mode=_TEXT if self.text else _ELEMENT,
            name=self.name,
            text=self.text.value().copy() if self.text else String(),
            payload=self.payload,
            uri=String(),
        )
        return deserialize[T](sub)

    def end(mut self) raises DeserializationError:
        pass


# A view of one value. `_FIELD` and `_ELEMENT` read the element at the
# reader, and differ only for seqs and maps: a field's are its run of
# same-named siblings, an element's are its children. `_TEXT` and `_ATTR`
# read `text`; `_EMPTY` is an absent field.
@fieldwise_init
struct XmlDe[origin: MutOrigin](Deserializer):
    var cur: Pointer[XmlReader, Self.origin]
    var mode: Int
    var name: StaticString
    var text: String
    # A variant payload shares its element with the `variant` attribute.
    var payload: Bool
    # `_MIXED`/`_PART`: the namespace the content's elements are in.
    var uri: String

    comptime repeat_policy = RepeatPolicy.AppendSeqs

    comptime SeqType = XmlSeqDe[Self.origin]
    comptime MapType = XmlMapDe[Self.origin]
    comptime StructType = XmlStructDe[Self.origin]
    comptime TupleType = XmlTupleDe[Self.origin]
    comptime EnumType = XmlEnumDe[Self.origin]

    def _missing(self) -> DeserializationError:
        return DeserializationError(
            String(t"missing field: {self.name}"), DerErrorKind.MissingField
        )

    # One part of mixed content: a run of text is the `XmlTextRun` arm, an
    # element the arm its name picks.
    def _part[
        arm_names: List[String]
    ](mut self) raises DeserializationError -> XmlEnumDe[Self.origin]:
        var idx = -1
        if self.mode == _TEXT_PART:
            comptime for i in range(len(arm_names)):
                comptime if arm_names[i] == "#text":
                    idx = i
            if idx < 0:
                raise _mismatch(
                    String(
                        "text in an XmlMixed field whose Variant has no"
                        " XmlTextRun arm"
                    )
                )
            return XmlEnumDe(
                cur=self.cur,
                idx=idx,
                name=self.name,
                text=self.text.copy(),
                payload=False,
            )
        var ev = self.cur[].peek()
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and ev.local == an and ev.uri == self.uri:
                idx = i
        if idx < 0:
            raise DeserializationError(
                String(t"unknown element <{ev.qname}> in mixed content"),
                DerErrorKind.UnknownVariant,
            )
        return XmlEnumDe(
            cur=self.cur, idx=idx, name=self.name, text=None, payload=False
        )

    def _element(self, what: StaticString) raises DeserializationError:
        if self.mode == _MIXED or self.mode == _PART or self.mode == _TEXT_PART:
            raise _mismatch(String(_MIXED_SHAPE))
        if self.mode == _TEXT:
            raise _mismatch(String(t"text content can't be {what}"))
        if self.mode == _ATTR:
            raise _mismatch(String(t"an attribute can't be {what}"))
        if self.mode == _EMPTY:
            raise self._missing()

    def _leaf(mut self) raises DeserializationError -> String:
        if self.mode == _MIXED or self.mode == _PART or self.mode == _TEXT_PART:
            raise _mismatch(String(_MIXED_SHAPE))
        if self.mode == _TEXT or self.mode == _ATTR:
            return self.text.copy()
        if self.mode == _EMPTY:
            raise self._missing()
        return self.cur[].leaf()

    def expect_bool(mut self) raises DeserializationError -> Bool:
        var t = String(self._leaf().strip())
        if t == "true" or t == "1":
            return True
        if t == "false" or t == "0":
            return False
        raise _invalid(String(t"invalid boolean: '{t}'"))

    def expect_number[
        DT: DType
    ](mut self) raises DeserializationError -> Scalar[DT]:
        return checked_scalar[DT](String(self._leaf().strip()))

    def expect_string(mut self) raises DeserializationError -> String:
        return self._leaf()

    def expect_bytes(mut self) raises DeserializationError -> List[Byte]:
        var hex = String(self._leaf().strip())
        var b = hex.as_bytes()
        if len(b) % 2 != 0:
            raise _invalid(String("odd-length hex"))
        var out = List[Byte](capacity=len(b) // 2)
        for i in range(0, len(b), 2):
            out.append(Byte(_nibble(Int(b[i])) * 16 + _nibble(Int(b[i + 1]))))
        return out^

    def expect_optional[
        T: Base
    ](mut self) raises DeserializationError -> Optional[T]:
        if self.mode == _EMPTY:
            return Optional[T]()
        if self.mode == _FIELD or self.mode == _ELEMENT:
            ref r = self.cur[]
            r.skip_misc()
            var nil = _attr_of(r.peek(), "nil")
            if nil and nil.value() == "true":
                r.skip_element()
                return Optional[T]()
        return Optional[T](deserialize[T](self))

    def begin_seq(mut self) raises DeserializationError -> Self.SeqType:
        if self.mode == _MIXED:
            return XmlSeqDe(
                cur=self.cur,
                run_uri=self.uri.copy(),
                run_local=String(),
                first=False,
                empty=False,
                mixed=True,
            )
        if self.mode == _EMPTY:
            return XmlSeqDe(
                cur=self.cur,
                run_uri=String(),
                run_local=String(),
                first=False,
                empty=True,
                mixed=False,
            )
        self._element("a list")
        ref r = self.cur[]
        if self.mode == _FIELD:
            r.skip_misc()
            var ev = r.peek()
            return XmlSeqDe(
                cur=self.cur,
                run_uri=ev.uri.copy(),
                run_local=ev.local.copy(),
                first=True,
                empty=False,
                mixed=False,
            )
        _ = r.start_element()
        return XmlSeqDe(
            cur=self.cur,
            run_uri=String(),
            run_local=String(),
            first=False,
            empty=False,
            mixed=False,
        )

    def begin_map(mut self) raises DeserializationError -> Self.MapType:
        var empty = self.mode == _EMPTY
        var uri = String()
        var local = String()
        if not empty:
            self._element("a map")
            ref r = self.cur[]
            if self.mode == _FIELD:
                r.skip_misc()
                var ev = r.peek()
                uri = ev.uri.copy()
                local = ev.local.copy()
            else:
                _ = r.start_element()
        return XmlMapDe(
            cur=self.cur,
            run_uri=uri^,
            run_local=local^,
            first=Bool(local),
            empty=empty,
            in_entry=False,
            got_key=False,
            got_value=False,
            held=[],
        )

    def begin_struct[
        T: AnyType
    ](mut self) raises DeserializationError -> Self.StructType:
        comptime assert _mixed_ok[T](), (
            "a struct with an XmlMixed field may have only attribute fields"
            " beside it"
        )
        self._element("a struct")
        comptime n = reflect[T].field_count()
        var st = XmlStructDe(
            cur=self.cur,
            attrs=[],
            names=List[StaticString](capacity=n),
            serve_absent=List[Bool](capacity=n),
            yielded=List[Bool](capacity=n),
            text_field=-1,
            mixed_field=-1,
            mixed_ns=String(),
            deny_unknown=count_struct_annotations[T, DenyUnknownFields]() > 0,
            phase=0,
            next=0,
            current=-1,
            mode=_EMPTY,
            value=String(),
        )
        comptime for i in range(n):
            st.names.append(static_wire_name[T, i]())
            st.serve_absent.append(not _fill_if_missing[T, i]())
            st.yielded.append(False)
            comptime if count_annotations[T, i, XmlText]() > 0:
                st.text_field = i
            comptime if count_annotations[T, i, XmlMixed]() > 0:
                st.mixed_field = i
                st.mixed_ns = _elem_ns[T, i]()

        ref r = self.cur[]
        var ev = r.start_element()
        if st.text_field >= 0:
            r.push_sink(ev.depth + 1)
        for a in ev.attrs:
            if a.uri == XMLNS_NS:
                continue
            if a.uri == "" and (
                a.local == "nil" or (self.payload and a.local == "variant")
            ):
                continue
            var i = _match[T](a.uri, a.local, True)
            if i < 0:
                if st.deny_unknown:
                    raise _unknown(a.qname)
                continue
            st.attrs.append(_FieldAttr(i, a.value.copy()))
        return st^

    def begin_tuple[
        field_count: Int
    ](mut self) raises DeserializationError -> Self.TupleType:
        self._element("a tuple")
        _ = self.cur[].start_element()
        return XmlTupleDe(cur=self.cur)

    def begin_enum[
        T: AnyType, arm_names: List[String]
    ](mut self) raises DeserializationError -> Self.EnumType:
        if self.mode == _TEXT_PART or self.mode == _PART:
            return self._part[arm_names]()
        self._element("a variant")
        ref r = self.cur[]
        r.skip_misc()
        var ev = r.peek()
        if ev.kind != _START:
            raise _invalid(String("expected an element"))
        var tag = _attr_of(ev, "variant")
        if not tag:
            raise _mismatch(String("expected a `variant` attribute"))
        var idx = -1
        comptime for i in range(len(arm_names)):
            comptime an = get_static_string[arm_names[i]]()
            if idx == -1 and tag.value() == an:
                idx = i
        return XmlEnumDe(
            cur=self.cur, idx=idx, name=self.name, text=None, payload=True
        )


def _read[
    T: Deinitable
](var text: String, out result: T) raises DeserializationError:
    var r = XmlReader(text^)
    var d = XmlDe(
        cur=Pointer(to=r),
        mode=_ELEMENT,
        name="root",
        text=String(),
        payload=False,
        uri=String(),
    )
    result = deserialize[T](d)
    while True:
        var k = d.cur[].next().kind
        if k == _EOF:
            return
        if k != _PI:
            raise _invalid(String("trailing content after the root element"))


def from_xml[
    T: Deinitable
](var s: String, out result: T) raises DeserializationError:
    result = _read[T](s^)


def from_xml_bytes[
    T: Deinitable
](var b: List[UInt8], out result: T) raises DeserializationError:
    result = _read[T](_decode(b))


def _canon_escape(mut out: String, v: StringSlice):
    var b = v.as_bytes()
    var run = 0
    for i in range(len(b)):
        var c = Int(b[i])
        var rep: StaticString
        if c == ord("&"):
            rep = "&amp;"
        elif c == ord("<"):
            rep = "&lt;"
        elif c == ord(">"):
            rep = "&gt;"
        elif c == ord('"'):
            rep = "&quot;"
        elif c == 0x9:
            rep = "&#9;"
        elif c == 0xA:
            rep = "&#10;"
        elif c == 0xD:
            rep = "&#13;"
        else:
            continue
        out += StringSlice(unsafe_from_utf8=b[run:i])
        out += rep
        run = i + 1
    out += StringSlice(unsafe_from_utf8=b[run:])


# The document in James Clark's canonical form, as the W3C conformance
# suite's expected outputs are written (the second form, with notations,
# when the DTD declares any).
def xml_canonical(var b: List[UInt8]) raises DeserializationError -> String:
    var r = XmlReader(_decode(b))
    var out = String()
    var notations_done = False
    while True:
        var ev = r.next()
        if ev.kind == _EOF:
            return out^
        if not notations_done and ev.kind == _START:
            notations_done = True
            if r.notations:
                var names = List[String]()
                for k in r.notations.keys():
                    var at = len(names)
                    while at > 0 and names[at - 1] > k:
                        at -= 1
                    names.insert(at, k.copy())
                out += "<!DOCTYPE " + r.doctype_name + " [\n"
                for k in names:
                    var n = r.notations.get(k).value().copy()
                    out += "<!NOTATION " + k
                    if n.public_id:
                        out += " PUBLIC '" + n.public_id.value() + "'"
                        if n.system_id:
                            out += " '" + n.system_id.value() + "'"
                    else:
                        out += " SYSTEM '" + n.system_id.value() + "'"
                    out += ">\n"
                out += "]>\n"
        if ev.kind == _START:
            out += "<" + ev.qname
            var order = List[Int]()
            for i in range(len(ev.attrs)):
                var at = len(order)
                while (
                    at > 0 and ev.attrs[order[at - 1]].qname > ev.attrs[i].qname
                ):
                    at -= 1
                order.insert(at, i)
            for i in order:
                out += " " + ev.attrs[i].qname + '="'
                _canon_escape(out, ev.attrs[i].value)
                out += '"'
            out += ">"
        elif ev.kind == _END:
            out += "</" + ev.qname + ">"
        elif ev.kind == _TEXT_EV:
            _canon_escape(out, ev.text)
        else:
            out += "<?" + ev.qname + " " + ev.text + "?>"
