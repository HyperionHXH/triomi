#!/usr/bin/env python3
"""Static DEX reference audit for locally frozen Mihon extension APKs.

The report proves only that externally referenced classes, methods, and fields
can be found in the plugin, the final host APK, or android.jar. It does not
execute plugins or establish runtime, network, native, reflective, or behavior
compatibility.
"""

from __future__ import annotations

import argparse
from collections import deque
from dataclasses import dataclass
import hashlib
import json
import re
import struct
import sys
from pathlib import Path, PurePosixPath
from typing import Iterable, Mapping, Sequence
from urllib.parse import unquote, urlparse
import xml.etree.ElementTree as ElementTree
import zipfile

try:
    from tools.check_mihon_abi import DexFormatError, _DexReader
except ModuleNotFoundError:
    from check_mihon_abi import DexFormatError, _DexReader


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_MIHON_HOST_SOURCE = (
    ROOT / "android/app/src/main/kotlin/io/github/hyperionhxh/triomi/MihonHost.kt"
)

ACC_PUBLIC = 0x0001
ACC_PRIVATE = 0x0002
ACC_PROTECTED = 0x0004
ACC_NATIVE = 0x0100

_DEX_NAME = re.compile(r"^classes(?:(\d+))?\.dex$")
_CLASS_DESCRIPTOR = re.compile(r"^L[^;]+;$")
_PARENT_PREFIXES = re.compile(
    r"parentPrefixes\s*=\s*(?:arrayOf|listOf)\s*\((.*?)\)", re.DOTALL
)
_KOTLIN_STRING = re.compile(r'"((?:\\.|[^"\\])*)"')
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_ANDROID_NAMESPACE = "http://schemas.android.com/apk/res/android"

_AXML_XML = 0x0003
_AXML_STRING_POOL = 0x0001
_AXML_START_ELEMENT = 0x0102
_AXML_UTF8_FLAG = 0x00000100
_AXML_NO_INDEX = 0xFFFFFFFF
_AXML_TYPE_STRING = 0x03
_AXML_TYPE_INT_DEC = 0x10
_AXML_TYPE_INT_HEX = 0x11
_MAX_ANDROID_MANIFEST_BYTES = 16 * 1024 * 1024

_DYNAMIC_METHOD_MARKERS = (
    "Ljava/lang/Class;->forName(",
    "Ljava/lang/Class;->getMethod(",
    "Ljava/lang/Class;->getDeclaredMethod(",
    "Ljava/lang/Class;->getConstructor(",
    "Ljava/lang/Class;->getDeclaredConstructor(",
    "Ljava/lang/Class;->getField(",
    "Ljava/lang/Class;->getDeclaredField(",
    "Ljava/lang/ClassLoader;->loadClass(",
    "Ljava/lang/reflect/Method;->invoke(",
    "Ljava/lang/reflect/Constructor;->newInstance(",
    "Ljava/lang/reflect/Field;->get(",
    "Ljava/lang/reflect/Field;->set(",
    "Ljava/util/ServiceLoader;->load(",
    "Ldalvik/system/DexClassLoader;",
    "Ldalvik/system/InMemoryDexClassLoader;",
)
_DEX_METADATA_CLASS_PREFIX = "Ldalvik/annotation/"
_PLACEHOLDER_PACKAGES = {
    "eu.kanade.tachiyomi.extension.all.keiyoushi",
    "eu.kanade.tachiyomi.extension.all.mihon",
}


class AuditInputError(ValueError):
    """A baseline input is invalid, so no trustworthy audit can be produced."""


class ClassFileFormatError(ValueError):
    """A class file in android.jar cannot be parsed safely."""


@dataclass
class BinaryClass:
    descriptor: str
    access_flags: int
    superclass: str | None
    interfaces: tuple[str, ...]
    methods: dict[str, int]
    fields: dict[str, int]


@dataclass
class DexScan:
    classes: dict[str, BinaryClass]
    class_refs: frozenset[str]
    method_refs: frozenset[str]
    field_refs: frozenset[str]
    dex_count: int
    duplicate_classes: frozenset[str]
    native_methods: frozenset[str]
    native_libraries: tuple[str, ...]


@dataclass(frozen=True)
class ApkIdentity:
    package_name: str
    version_code: int | None = None
    version_name: str | None = None


@dataclass(frozen=True)
class _ArtifactExpectations:
    sha256: tuple[tuple[str, str], ...] = ()
    asset_sha256: tuple[tuple[str, str], ...] = ()
    sizes: tuple[tuple[str, int], ...] = ()
    validations: tuple[tuple[str, object], ...] = ()
    package_name: str | None = None
    version_code: int | None = None
    version_name: str | None = None

    @property
    def digests(self) -> tuple[str, ...]:
        return tuple(
            dict.fromkeys(
                value
                for _, value in (*self.sha256, *self.asset_sha256)
            )
        )

    @property
    def expected_bytes(self) -> tuple[int, ...]:
        return tuple(dict.fromkeys(value for _, value in self.sizes))

    def report(self) -> dict[str, object]:
        result: dict[str, object] = {}
        if self.sha256:
            result["sha256"] = [
                {"field": field, "value": value} for field, value in self.sha256
            ]
        if self.asset_sha256:
            result["assetSha256"] = [
                {"field": field, "value": value}
                for field, value in self.asset_sha256
            ]
        if self.sizes:
            result["bytes"] = [
                {"field": field, "value": value} for field, value in self.sizes
            ]
        if self.validations:
            result["validation"] = [
                {"field": field, "value": value}
                for field, value in self.validations
            ]
        identity: dict[str, object] = {}
        if self.package_name is not None:
            identity["packageName"] = self.package_name
        if self.version_code is not None:
            identity["versionCode"] = self.version_code
        if self.version_name is not None:
            identity["versionName"] = self.version_name
        if identity:
            result["identity"] = identity
        return result


@dataclass(frozen=True)
class _ApkBinding:
    path: Path | None
    error: str | None
    evidence: tuple[str, ...] = ()
    identity: ApkIdentity | None = None
    expectations: _ArtifactExpectations = _ArtifactExpectations()


@dataclass(frozen=True)
class MemberResolution:
    status: str
    source: str | None = None
    declaring_class: str | None = None
    declaring_access: int = 0
    member_access: int = 0
    unresolved_ancestors: tuple[str, ...] = ()


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def _decode_axml_string_length(
    data: bytes, offset: int, end: int, *, utf16: bool
) -> tuple[int, int]:
    if utf16:
        if offset + 2 > end:
            raise ValueError("truncated Android string-pool length")
        length = struct.unpack_from("<H", data, offset)[0]
        offset += 2
        if length & 0x8000:
            if offset + 2 > end:
                raise ValueError("truncated Android string-pool length")
            length = ((length & 0x7FFF) << 16) | struct.unpack_from(
                "<H", data, offset
            )[0]
            offset += 2
        return length, offset
    if offset >= end:
        raise ValueError("truncated Android string-pool length")
    length = data[offset]
    offset += 1
    if length & 0x80:
        if offset >= end:
            raise ValueError("truncated Android string-pool length")
        length = ((length & 0x7F) << 8) | data[offset]
        offset += 1
    return length, offset


def _parse_axml_string_pool(
    data: bytes, offset: int, header_size: int, chunk_size: int
) -> tuple[str, ...]:
    end = offset + chunk_size
    if header_size < 28 or end > len(data):
        raise ValueError("invalid Android string-pool header")
    (
        string_count,
        style_count,
        flags,
        strings_start,
        styles_start,
    ) = struct.unpack_from("<IIIII", data, offset + 8)
    offsets_start = offset + header_size
    offsets_end = offsets_start + (string_count + style_count) * 4
    strings_base = offset + strings_start
    if (
        offsets_end > end
        or strings_base < offsets_end
        or strings_base > end
        or (styles_start and offset + styles_start > end)
    ):
        raise ValueError("invalid Android string-pool offsets")

    utf16 = not flags & _AXML_UTF8_FLAG
    strings: list[str] = []
    for index in range(string_count):
        string_offset = struct.unpack_from(
            "<I", data, offsets_start + index * 4
        )[0]
        position = strings_base + string_offset
        if position >= end:
            raise ValueError("Android string-pool index is out of range")
        if utf16:
            character_count, position = _decode_axml_string_length(
                data, position, end, utf16=True
            )
            byte_count = character_count * 2
            if position + byte_count > end:
                raise ValueError("truncated UTF-16 Android string")
            try:
                value = data[position : position + byte_count].decode("utf-16le")
            except UnicodeDecodeError as error:
                raise ValueError("invalid UTF-16 Android string") from error
        else:
            _, position = _decode_axml_string_length(
                data, position, end, utf16=False
            )
            byte_count, position = _decode_axml_string_length(
                data, position, end, utf16=False
            )
            if position + byte_count > end:
                raise ValueError("truncated UTF-8 Android string")
            try:
                value = data[position : position + byte_count].decode("utf-8")
            except UnicodeDecodeError as error:
                raise ValueError("invalid UTF-8 Android string") from error
        strings.append(value)
    return tuple(strings)


def _axml_string(strings: Sequence[str], index: int) -> str | None:
    if index == _AXML_NO_INDEX:
        return None
    if not 0 <= index < len(strings):
        raise ValueError("Android XML string index is out of range")
    return strings[index]


def _axml_attribute_value(
    strings: Sequence[str],
    raw_index: int,
    data_type: int,
    data_value: int,
) -> str | None:
    if raw_index != _AXML_NO_INDEX:
        return _axml_string(strings, raw_index)
    if data_type == _AXML_TYPE_STRING:
        return _axml_string(strings, data_value)
    if data_type in (_AXML_TYPE_INT_DEC, _AXML_TYPE_INT_HEX):
        signed = data_value if data_value < 0x80000000 else data_value - 0x100000000
        return str(signed)
    return None


def _parse_binary_android_manifest(data: bytes) -> ApkIdentity:
    if len(data) < 8:
        raise ValueError("truncated Android binary XML")
    chunk_type, header_size, total_size = struct.unpack_from("<HHI", data, 0)
    if (
        chunk_type != _AXML_XML
        or header_size < 8
        or total_size > len(data)
        or total_size < header_size
    ):
        raise ValueError("invalid Android binary XML header")

    strings: tuple[str, ...] = ()
    offset = header_size
    while offset + 8 <= total_size:
        inner_type, inner_header, inner_size = struct.unpack_from(
            "<HHI", data, offset
        )
        if (
            inner_header < 8
            or inner_size < inner_header
            or offset + inner_size > total_size
        ):
            raise ValueError("invalid Android binary XML chunk")
        if inner_type == _AXML_STRING_POOL:
            strings = _parse_axml_string_pool(data, offset, inner_header, inner_size)
        elif inner_type == _AXML_START_ELEMENT:
            if inner_header < 16 or inner_size < 36:
                raise ValueError("truncated Android XML start element")
            name = _axml_string(
                strings, struct.unpack_from("<I", data, offset + 20)[0]
            )
            if name != "manifest":
                raise ValueError("AndroidManifest.xml root is not manifest")
            attribute_start, attribute_size, attribute_count = struct.unpack_from(
                "<HHH", data, offset + 24
            )
            if attribute_size < 20:
                raise ValueError("invalid Android XML attribute size")
            attributes_offset = offset + 16 + attribute_start
            if (
                attributes_offset
                + attribute_count * attribute_size
                > offset + inner_size
            ):
                raise ValueError("truncated Android XML attributes")

            package_name: str | None = None
            version_code: int | None = None
            version_name: str | None = None
            for index in range(attribute_count):
                position = attributes_offset + index * attribute_size
                namespace_index, name_index, raw_index = struct.unpack_from(
                    "<III", data, position
                )
                data_type = data[position + 15]
                data_value = struct.unpack_from("<I", data, position + 16)[0]
                attribute_name = _axml_string(strings, name_index)
                namespace = _axml_string(strings, namespace_index)
                value = _axml_attribute_value(
                    strings, raw_index, data_type, data_value
                )
                if not namespace and attribute_name == "package":
                    package_name = value
                elif (
                    namespace == _ANDROID_NAMESPACE
                    and attribute_name == "versionCode"
                    and value is not None
                ):
                    version_code = int(value, 0)
                elif (
                    namespace == _ANDROID_NAMESPACE
                    and attribute_name == "versionName"
                ):
                    version_name = value
            if not package_name:
                raise ValueError("AndroidManifest.xml has no package name")
            return ApkIdentity(package_name, version_code, version_name)
        offset += inner_size
    raise ValueError("AndroidManifest.xml has no manifest element")


def _parse_text_android_manifest(data: bytes) -> ApkIdentity:
    try:
        root = ElementTree.fromstring(data.decode("utf-8-sig"))
    except (UnicodeDecodeError, ElementTree.ParseError) as error:
        raise ValueError("invalid textual AndroidManifest.xml") from error
    if root.tag.rsplit("}", 1)[-1] != "manifest":
        raise ValueError("AndroidManifest.xml root is not manifest")
    package_name = root.attrib.get("package")
    if not package_name:
        raise ValueError("AndroidManifest.xml has no package name")
    version_code_text = root.attrib.get(f"{{{_ANDROID_NAMESPACE}}}versionCode")
    try:
        version_code = int(version_code_text, 0) if version_code_text else None
    except ValueError as error:
        raise ValueError("AndroidManifest.xml versionCode is invalid") from error
    return ApkIdentity(
        package_name,
        version_code,
        root.attrib.get(f"{{{_ANDROID_NAMESPACE}}}versionName"),
    )


def _read_apk_identity(apk_path: Path) -> ApkIdentity:
    try:
        archive = zipfile.ZipFile(apk_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise ValueError(f"{apk_path}: cannot read APK manifest: {error}") from error
    with archive:
        names = [
            name for name in archive.namelist() if name == "AndroidManifest.xml"
        ]
        if len(names) != 1:
            raise ValueError(
                f"{apk_path}: APK must contain exactly one AndroidManifest.xml"
            )
        info = archive.getinfo(names[0])
        if info.file_size > _MAX_ANDROID_MANIFEST_BYTES:
            raise ValueError(f"{apk_path}: AndroidManifest.xml is too large")
        data = archive.read(names[0])
    stripped = data.lstrip()
    if stripped.startswith(b"\xef\xbb\xbf"):
        stripped = stripped[3:].lstrip()
    if stripped.startswith(b"<"):
        return _parse_text_android_manifest(data)
    return _parse_binary_android_manifest(data)


def _dex_sort_key(name: str) -> int:
    match = _DEX_NAME.fullmatch(name)
    if match is None:
        return sys.maxsize
    return int(match.group(1) or "1")


def _referenced_class(descriptor: str) -> str | None:
    while descriptor.startswith("["):
        descriptor = descriptor[1:]
    return descriptor if _CLASS_DESCRIPTOR.fullmatch(descriptor) else None


def _merge_class(
    classes: dict[str, BinaryClass],
    duplicate_classes: set[str],
    incoming: BinaryClass,
) -> None:
    previous = classes.get(incoming.descriptor)
    if previous is None:
        classes[incoming.descriptor] = incoming
        return
    duplicate_classes.add(incoming.descriptor)
    methods = dict(previous.methods)
    for name, access in incoming.methods.items():
        methods[name] = methods.get(name, 0) | access
    fields = dict(previous.fields)
    for name, access in incoming.fields.items():
        fields[name] = fields.get(name, 0) | access
    classes[incoming.descriptor] = BinaryClass(
        descriptor=incoming.descriptor,
        access_flags=previous.access_flags | incoming.access_flags,
        superclass=previous.superclass or incoming.superclass,
        interfaces=tuple(dict.fromkeys(previous.interfaces + incoming.interfaces)),
        methods=methods,
        fields=fields,
    )


def _read_dex_members(
    reader: _DexReader,
    class_data_offset: int,
) -> tuple[dict[str, int], dict[str, int], set[str]]:
    methods: dict[str, int] = {}
    fields: dict[str, int] = {}
    native_methods: set[str] = set()
    if class_data_offset == 0:
        return methods, fields, native_methods

    static_fields, offset = reader.uleb(class_data_offset)
    instance_fields, offset = reader.uleb(offset)
    direct_methods, offset = reader.uleb(offset)
    virtual_methods, offset = reader.uleb(offset)

    for count in (static_fields, instance_fields):
        field_index = 0
        for _ in range(count):
            delta, offset = reader.uleb(offset)
            access, offset = reader.uleb(offset)
            field_index += delta
            descriptor = reader.field_descriptor(field_index).split("->", 1)[1]
            fields[descriptor] = fields.get(descriptor, 0) | access

    for count in (direct_methods, virtual_methods):
        method_index = 0
        for _ in range(count):
            delta, offset = reader.uleb(offset)
            access, offset = reader.uleb(offset)
            _, offset = reader.uleb(offset)
            method_index += delta
            owner, name, proto = reader.method_parts(method_index)
            descriptor = name + proto
            methods[descriptor] = methods.get(descriptor, 0) | access
            if access & ACC_NATIVE:
                native_methods.add(f"{owner}->{descriptor}")
    return methods, fields, native_methods


def parse_dex_scan(data: bytes, source: str) -> DexScan:
    reader = _DexReader(data, source)
    classes: dict[str, BinaryClass] = {}
    duplicate_classes: set[str] = set()
    native_methods: set[str] = set()
    class_refs: set[str] = set()
    method_refs: set[str] = set()
    field_refs: set[str] = set()

    for type_index in range(len(reader.type_ids)):
        referenced = _referenced_class(reader.type(type_index))
        if referenced is not None:
            class_refs.add(referenced)

    for field_index in range(len(reader.field_ids)):
        descriptor = reader.field_descriptor(field_index)
        owner = descriptor.split("->", 1)[0]
        referenced_owner = _referenced_class(owner)
        if referenced_owner is not None:
            class_refs.add(referenced_owner)
        field_refs.add(descriptor)

    for method_index in range(len(reader.method_ids)):
        owner, name, proto = reader.method_parts(method_index)
        referenced_owner = _referenced_class(owner)
        if referenced_owner is not None:
            class_refs.add(referenced_owner)
        method_refs.add(f"{owner}->{name}{proto}")

    for class_offset in reader.class_defs:
        descriptor = reader.type(reader.u32(class_offset))
        access = reader.u32(class_offset + 4)
        superclass_index = reader.u32(class_offset + 8)
        superclass = (
            None if superclass_index == 0xFFFFFFFF else reader.type(superclass_index)
        )
        interfaces = reader.type_list(reader.u32(class_offset + 12))
        methods, fields, class_native_methods = _read_dex_members(
            reader, reader.u32(class_offset + 24)
        )
        native_methods.update(class_native_methods)
        _merge_class(
            classes,
            duplicate_classes,
            BinaryClass(
                descriptor=descriptor,
                access_flags=access,
                superclass=superclass,
                interfaces=interfaces,
                methods=methods,
                fields=fields,
            ),
        )

    return DexScan(
        classes=classes,
        class_refs=frozenset(class_refs),
        method_refs=frozenset(method_refs),
        field_refs=frozenset(field_refs),
        dex_count=1,
        duplicate_classes=frozenset(duplicate_classes),
        native_methods=frozenset(native_methods),
        native_libraries=(),
    )


def parse_apk_dex(apk_path: Path) -> DexScan:
    try:
        archive = zipfile.ZipFile(apk_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise DexFormatError(f"{apk_path}: cannot read APK: {error}") from error

    classes: dict[str, BinaryClass] = {}
    duplicate_classes: set[str] = set()
    class_refs: set[str] = set()
    method_refs: set[str] = set()
    field_refs: set[str] = set()
    native_methods: set[str] = set()
    native_libraries: list[str] = []
    dex_names: list[str] = []
    with archive:
        for name in archive.namelist():
            if _DEX_NAME.fullmatch(name):
                dex_names.append(name)
            elif name.startswith("lib/") and name.endswith(".so"):
                native_libraries.append(name)
        dex_names.sort(key=_dex_sort_key)
        if not dex_names:
            raise DexFormatError(f"{apk_path}: APK contains no classes*.dex")
        for name in dex_names:
            scan = parse_dex_scan(archive.read(name), f"{apk_path}!{name}")
            for descriptor, info in scan.classes.items():
                _merge_class(classes, duplicate_classes, info)
            class_refs.update(scan.class_refs)
            method_refs.update(scan.method_refs)
            field_refs.update(scan.field_refs)
            native_methods.update(scan.native_methods)

    return DexScan(
        classes=classes,
        class_refs=frozenset(class_refs),
        method_refs=frozenset(method_refs),
        field_refs=frozenset(field_refs),
        dex_count=len(dex_names),
        duplicate_classes=frozenset(duplicate_classes),
        native_methods=frozenset(native_methods),
        native_libraries=tuple(sorted(native_libraries)),
    )


class _ClassFileReader:
    def __init__(self, data: bytes, source: str) -> None:
        self.data = data
        self.source = source
        self.offset = 0

    def _take(self, size: int) -> bytes:
        end = self.offset + size
        if size < 0 or end > len(self.data):
            raise ClassFileFormatError(f"{self.source}: truncated class file")
        value = self.data[self.offset:end]
        self.offset = end
        return value

    def u1(self) -> int:
        return self._take(1)[0]

    def u2(self) -> int:
        return struct.unpack(">H", self._take(2))[0]

    def u4(self) -> int:
        return struct.unpack(">I", self._take(4))[0]

    def skip_attributes(self) -> None:
        count = self.u2()
        for _ in range(count):
            self.u2()
            self._take(self.u4())

    def parse(self) -> BinaryClass:
        if self.u4() != 0xCAFEBABE:
            raise ClassFileFormatError(f"{self.source}: invalid class-file magic")
        self.u2()
        self.u2()
        constant_pool_count = self.u2()
        constant_pool: list[object | None] = [None] * constant_pool_count
        index = 1
        while index < constant_pool_count:
            tag = self.u1()
            if tag == 1:
                length = self.u2()
                constant_pool[index] = (1, self._take(length))
            elif tag in (3, 4):
                constant_pool[index] = (tag, self._take(4))
            elif tag in (5, 6):
                constant_pool[index] = (tag, self._take(8))
                index += 1
            elif tag in (7, 8, 16, 19, 20):
                constant_pool[index] = (tag, self.u2())
            elif tag in (9, 10, 11, 12, 17, 18):
                constant_pool[index] = (tag, self.u2(), self.u2())
            elif tag == 15:
                constant_pool[index] = (tag, self.u1(), self.u2())
            else:
                raise ClassFileFormatError(
                    f"{self.source}: unsupported constant-pool tag {tag}"
                )
            index += 1

        access = self.u2()
        this_class = self.u2()
        super_class = self.u2()
        interface_count = self.u2()
        interfaces = tuple(
            f"L{_class_file_class_name(constant_pool, self.u2())};"
            for _ in range(interface_count)
        )
        fields: dict[str, int] = {}
        field_count = self.u2()
        for _ in range(field_count):
            field_access = self.u2()
            name = _class_file_utf8(constant_pool, self.u2())
            descriptor = _class_file_utf8(constant_pool, self.u2())
            self.skip_attributes()
            fields[f"{name}:{descriptor}"] = field_access

        methods: dict[str, int] = {}
        method_count = self.u2()
        for _ in range(method_count):
            method_access = self.u2()
            name = _class_file_utf8(constant_pool, self.u2())
            descriptor = _class_file_utf8(constant_pool, self.u2())
            self.skip_attributes()
            methods[name + descriptor] = method_access

        self.skip_attributes()
        binary_name = _class_file_class_name(constant_pool, this_class)
        superclass = (
            None
            if super_class == 0
            else f"L{_class_file_class_name(constant_pool, super_class)};"
        )
        return BinaryClass(
            descriptor=f"L{binary_name};",
            access_flags=access,
            superclass=superclass,
            interfaces=interfaces,
            methods=methods,
            fields=fields,
        )


def _class_file_utf8(constant_pool: Sequence[object | None], index: int) -> str:
    if not 0 < index < len(constant_pool):
        raise ClassFileFormatError("class-file UTF-8 index is out of range")
    entry = constant_pool[index]
    if not isinstance(entry, tuple) or not entry or entry[0] != 1:
        raise ClassFileFormatError("class-file constant is not UTF-8")
    raw = entry[1]
    if not isinstance(raw, bytes):
        raise ClassFileFormatError("class-file UTF-8 payload is invalid")
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ClassFileFormatError("class-file UTF-8 payload is invalid") from error


def _class_file_class_name(
    constant_pool: Sequence[object | None], index: int
) -> str:
    if not 0 < index < len(constant_pool):
        raise ClassFileFormatError("class-file class index is out of range")
    entry = constant_pool[index]
    if not isinstance(entry, tuple) or not entry or entry[0] != 7:
        raise ClassFileFormatError("class-file constant is not a class")
    name_index = entry[1]
    if not isinstance(name_index, int):
        raise ClassFileFormatError("class-file class name index is invalid")
    return _class_file_utf8(constant_pool, name_index)


def parse_android_jar(jar_path: Path) -> dict[str, BinaryClass]:
    classes: dict[str, BinaryClass] = {}
    duplicates: set[str] = set()
    try:
        archive = zipfile.ZipFile(jar_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise AuditInputError(f"{jar_path}: cannot read android.jar: {error}") from error
    with archive:
        for name in sorted(archive.namelist()):
            if not name.endswith(".class"):
                continue
            if name.startswith("META-INF/") or name.endswith("module-info.class"):
                continue
            info = _ClassFileReader(
                archive.read(name), f"{jar_path}!{name}"
            ).parse()
            _merge_class(classes, duplicates, info)
    if not classes:
        raise AuditInputError(f"{jar_path}: android.jar contains no class files")
    return classes


def parse_parent_first_prefixes(source_text: str) -> tuple[str, ...]:
    match = _PARENT_PREFIXES.search(source_text)
    if match is None:
        raise AuditInputError(
            "MihonHost source does not contain a parseable parentPrefixes array"
        )
    prefixes = tuple(
        value.replace("\\\\", "\\").replace('\\"', '"')
        for value in _KOTLIN_STRING.findall(match.group(1))
    )
    if not prefixes or any(not prefix.strip() for prefix in prefixes):
        raise AuditInputError("MihonHost parentPrefixes is empty or invalid")
    return tuple(prefix.strip() for prefix in prefixes)


class SymbolUniverse:
    def __init__(
        self,
        plugin: Mapping[str, BinaryClass],
        host: Mapping[str, BinaryClass],
        android: Mapping[str, BinaryClass],
        parent_prefixes: Sequence[str],
    ) -> None:
        self.plugin = plugin
        self.host = host
        self.android = android
        self.parent_prefixes = tuple(parent_prefixes)

    def _binary_name(self, descriptor: str) -> str:
        return descriptor[1:-1].replace("/", ".")

    def _is_parent_first(self, descriptor: str) -> bool:
        name = self._binary_name(descriptor)
        return any(name.startswith(prefix) for prefix in self.parent_prefixes)

    def parent_lookup(self, descriptor: str) -> tuple[BinaryClass, str] | None:
        info = self.android.get(descriptor)
        if info is not None:
            return info, "android"
        info = self.host.get(descriptor)
        if info is not None:
            return info, "host"
        return None

    def lookup_class(self, descriptor: str) -> tuple[BinaryClass, str] | None:
        parent_first = self._is_parent_first(descriptor)
        if parent_first:
            parent = self.parent_lookup(descriptor)
            if parent is not None:
                return parent
        info = self.plugin.get(descriptor)
        if info is not None:
            return info, "plugin"
        if not parent_first:
            info = self.android.get(descriptor)
            if info is not None:
                return info, "android"
            info = self.host.get(descriptor)
            if info is not None:
                return info, "host"
        return None

    def resolve_method(self, descriptor: str) -> MemberResolution:
        owner, member = descriptor.split("->", 1)
        if owner.startswith("["):
            if member == "clone()Ljava/lang/Object;":
                return MemberResolution(
                    status="resolved",
                    source="android",
                    declaring_class=owner,
                    declaring_access=ACC_PUBLIC,
                    member_access=ACC_PUBLIC,
                )
            return self._resolve_member(
                "Ljava/lang/Object;", member, kind="methods"
            )
        owner_info = self.lookup_class(owner)
        if owner_info is None:
            return MemberResolution(status="missing-class")
        if member.startswith("<init>"):
            info, source = owner_info
            access = info.methods.get(member)
            if access is None:
                return MemberResolution(status="missing-member")
            return MemberResolution(
                status="resolved",
                source=source,
                declaring_class=owner,
                declaring_access=info.access_flags,
                member_access=access,
            )
        return self._resolve_member(owner, member, kind="methods")

    def resolve_field(self, descriptor: str) -> MemberResolution:
        owner, member = descriptor.split("->", 1)
        if self.lookup_class(owner) is None:
            return MemberResolution(status="missing-class")
        return self._resolve_member(owner, member, kind="fields")

    def _resolve_member(
        self, owner: str, member: str, kind: str
    ) -> MemberResolution:
        pending = deque((owner,))
        visited: set[str] = set()
        unresolved_ancestors: set[str] = set()
        while pending:
            descriptor = pending.popleft()
            if descriptor in visited:
                continue
            visited.add(descriptor)
            resolved = self.lookup_class(descriptor)
            if resolved is None:
                unresolved_ancestors.add(descriptor)
                continue
            info, source = resolved
            access = getattr(info, kind).get(member)
            if access is not None and (
                descriptor == owner or not access & ACC_PRIVATE
            ):
                return MemberResolution(
                    status="resolved",
                    source=source,
                    declaring_class=descriptor,
                    declaring_access=info.access_flags,
                    member_access=access,
                )
            if info.superclass is not None:
                pending.append(info.superclass)
            pending.extend(info.interfaces)
        if unresolved_ancestors:
            return MemberResolution(
                status="indeterminate",
                unresolved_ancestors=tuple(sorted(unresolved_ancestors)),
            )
        return MemberResolution(status="missing-member")


def external_references(
    scan: DexScan,
) -> tuple[set[str], set[str], set[str]]:
    defined_classes = set(scan.classes)
    defined_methods = {
        f"{owner}->{member}"
        for owner, info in scan.classes.items()
        for member in info.methods
    }
    defined_fields = {
        f"{owner}->{member}"
        for owner, info in scan.classes.items()
        for member in info.fields
    }
    return (
        set(scan.class_refs) - defined_classes,
        set(scan.method_refs) - defined_methods,
        set(scan.field_refs) - defined_fields,
    )


def _ratio(resolved: int, total: int) -> float | None:
    return None if total == 0 else round(resolved / total, 6)


def _coverage_bucket(resolved: int, missing: int, indeterminate: int) -> dict[str, object]:
    total = resolved + missing + indeterminate
    return {
        "total": total,
        "resolved": resolved,
        "missing": missing,
        "indeterminate": indeterminate,
        "ratio": _ratio(resolved, total),
    }


def _selected_metadata(record: Mapping[str, object]) -> dict[str, object]:
    result: dict[str, object] = {}
    aliases = {
        "pkg": ("pkg", "packageName", "package_name", "package"),
        "name": ("name",),
        "version": ("version", "versionName", "version_name"),
        "versionCode": ("versionCode", "version_code", "code"),
        "lang": ("lang",),
        "extensionLib": ("extensionLib", "extension_lib"),
    }
    for key, candidates in aliases.items():
        value = None
        for candidate in candidates:
            if record.get(candidate) is not None:
                value = record.get(candidate)
                break
        if isinstance(value, (str, int, float, bool)) and value not in ("", None):
            result[key] = value
    sources = record.get("sources")
    if isinstance(sources, list):
        result["sourceCount"] = len(sources)
    for key in (
        "sha256",
        "apkSha256",
        "apk_sha256",
        "asset_sha256",
        "assetSha256",
        "size",
        "bytes",
        "apkSize",
        "apk_size",
        "asset_size",
        "assetSize",
    ):
        if record.get(key) is not None:
            result[key] = record[key]

    resources = record.get("resources")
    if isinstance(resources, dict):
        selected_resources = {
            key: resources[key]
            for key in (
                "apk",
                "sha256",
                "apkSha256",
                "apk_sha256",
                "asset_sha256",
                "assetSha256",
                "size",
                "bytes",
                "apkSize",
                "apk_size",
                "asset_size",
                "assetSize",
            )
            if resources.get(key) is not None
        }
        if selected_resources:
            result["resources"] = selected_resources

    download = record.get("download")
    if isinstance(download, dict):
        selected_download = {
            key: download[key]
            for key in (
                "status",
                "local_path",
                "sha256",
                "apkSha256",
                "apk_sha256",
                "asset_sha256",
                "assetSha256",
                "validation",
                "size",
                "bytes",
                "apkSize",
                "apk_size",
                "asset_size",
                "assetSize",
            )
            if download.get(key) is not None
        }
        if selected_download:
            result["download"] = selected_download
        if isinstance(download.get("status"), str):
            result["downloadStatus"] = download["status"]
    return result


def load_manifest(path: Path) -> list[dict[str, object]]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise AuditInputError(f"{path}: cannot read manifest: {error}") from error
    try:
        payload = json.loads(text)
    except json.JSONDecodeError as single_error:
        records = []
        for line_number, line in enumerate(text.splitlines(), start=1):
            if not line.strip():
                continue
            try:
                item = json.loads(line)
            except json.JSONDecodeError:
                raise AuditInputError(
                    f"{path}: cannot parse JSON or JSONL "
                    f"(line {line_number}; first error: {single_error})"
                ) from single_error
            if not isinstance(item, dict):
                raise AuditInputError(
                    f"{path}: JSONL line {line_number} is not an object"
                )
            records.append(dict(item))
        payload = records
    if isinstance(payload, dict):
        extension_list = payload.get("extensionList")
        if isinstance(extension_list, dict):
            payload = extension_list.get("extensions")
        else:
            original = payload
            matched_container = False
            for key in ("extensions", "plugins", "entries", "index"):
                if key in original:
                    payload = original[key]
                    matched_container = True
                    break
            if not matched_container and any(
                key in original
                for key in (
                    "pkg",
                    "packageName",
                    "package_name",
                    "package",
                    "apk",
                    "download",
                )
            ):
                payload = [original]
    if not isinstance(payload, list) or not payload:
        raise AuditInputError(f"{path}: manifest must contain a non-empty array")
    records: list[dict[str, object]] = []
    for index, item in enumerate(payload):
        if not isinstance(item, dict):
            raise AuditInputError(f"{path}: entry {index} is not an object")
        records.append(dict(item))
    return records


def _manifest_id(record: Mapping[str, object], index: int) -> str:
    for key in (
        "pkg",
        "packageName",
        "package",
        "name",
        "apk",
        "apkPath",
        "apkFile",
        "file",
        "fileName",
        "path",
    ):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            return value
    return f"manifest-entry-{index + 1}"


def manifest_warnings(records: Sequence[Mapping[str, object]]) -> list[dict[str, object]]:
    packages = {
        str(
            record.get("pkg")
            or record.get("packageName")
            or record.get("package_name")
            or ""
        )
        for record in records
    }
    if records and packages and packages <= _PLACEHOLDER_PACKAGES:
        return [
            {
                "code": "manifest-may-be-keiyoushi-status-stub",
                "detail": (
                    "Every manifest entry is a Keiyoushi/Mihon status placeholder. "
                    "This is not a full extension inventory."
                ),
                "entryCount": len(records),
            }
        ]
    return []


def _is_within(path: Path, root: Path) -> bool:
    try:
        path.resolve().relative_to(root.resolve())
        return True
    except ValueError:
        return False


class _ManifestBindingError(ValueError):
    def __init__(
        self,
        reason: str,
        expectations: _ArtifactExpectations | None = None,
    ) -> None:
        super().__init__(reason)
        self.reason = reason
        self.expectations = expectations


def _manifest_text(
    record: Mapping[str, object], keys: Sequence[str], reason: str
) -> str | None:
    values = {
        value.strip()
        for key in keys
        for value in (record.get(key),)
        if isinstance(value, str) and value.strip()
    }
    if len(values) > 1:
        raise _ManifestBindingError(reason)
    return next(iter(values), None)


def _manifest_int(
    value: object, *, reason: str, minimum: int = 0
) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool):
        raise _ManifestBindingError(reason)
    if isinstance(value, int):
        result = value
    elif isinstance(value, str) and value.strip():
        try:
            result = int(value.strip(), 10)
        except ValueError as error:
            raise _ManifestBindingError(reason) from error
    else:
        raise _ManifestBindingError(reason)
    if result < minimum:
        raise _ManifestBindingError(reason)
    return result


def _manifest_digest(value: object, reason: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise _ManifestBindingError(reason)
    digest = value.strip().lower()
    if digest.startswith("sha256:"):
        digest = digest[7:]
    if not _SHA256.fullmatch(digest):
        raise _ManifestBindingError(reason)
    return digest


def _validation_failed(value: object) -> bool:
    if value is False:
        return True
    if isinstance(value, Mapping):
        if value.get("ok") is False:
            return True
        return any(_validation_failed(item) for item in value.values())
    if isinstance(value, list):
        return any(_validation_failed(item) for item in value)
    return False


def _artifact_expectations(
    record: Mapping[str, object],
) -> _ArtifactExpectations:
    sha_values: list[tuple[str, str]] = []
    asset_sha_values: list[tuple[str, str]] = []
    size_values: list[tuple[str, int]] = []
    validations: list[tuple[str, object]] = []

    def add_digest(
        target: list[tuple[str, str]], field: str, value: object
    ) -> None:
        digest = _manifest_digest(value, "manifest-integrity-invalid")
        if digest is not None:
            target.append((field, digest))

    def add_size(field: str, value: object) -> None:
        size = _manifest_int(
            value, reason="manifest-integrity-invalid", minimum=0
        )
        if size is not None:
            size_values.append((field, size))

    for key in ("sha256", "apkSha256", "apk_sha256"):
        add_digest(sha_values, key, record.get(key))
    for key in ("asset_sha256", "assetSha256"):
        add_digest(asset_sha_values, key, record.get(key))
    for key in (
        "size",
        "bytes",
        "apkSize",
        "apk_size",
        "asset_size",
        "assetSize",
    ):
        add_size(key, record.get(key))
    if record.get("validation") is not None:
        validations.append(("validation", record["validation"]))

    resources = record.get("resources")
    if isinstance(resources, Mapping):
        for key in ("sha256", "apkSha256", "apk_sha256"):
            add_digest(sha_values, f"resources.{key}", resources.get(key))
        for key in ("asset_sha256", "assetSha256"):
            add_digest(
                asset_sha_values, f"resources.{key}", resources.get(key)
            )
        for key in (
            "size",
            "bytes",
            "apkSize",
            "apk_size",
            "asset_size",
            "assetSize",
        ):
            add_size(f"resources.{key}", resources.get(key))
        if resources.get("validation") is not None:
            validations.append(
                ("resources.validation", resources["validation"])
            )

    download = record.get("download")
    if isinstance(download, Mapping):
        for key in ("sha256", "apkSha256", "apk_sha256"):
            add_digest(sha_values, f"download.{key}", download.get(key))
        for key in ("asset_sha256", "assetSha256"):
            add_digest(
                asset_sha_values, f"download.{key}", download.get(key)
            )
        for key in (
            "size",
            "bytes",
            "apkSize",
            "apk_size",
            "asset_size",
            "assetSize",
        ):
            add_size(f"download.{key}", download.get(key))
        if download.get("validation") is not None:
            validations.append(
                ("download.validation", download["validation"])
            )

    package_name = _manifest_text(
        record,
        ("pkg", "packageName", "package_name", "package"),
        "manifest-identity-ambiguous",
    )
    version_name = _manifest_text(
        record,
        ("version", "versionName", "version_name"),
        "manifest-identity-ambiguous",
    )
    version_code = _manifest_int(
        next(
            (
                record[key]
                for key in ("versionCode", "version_code", "code")
                if record.get(key) is not None
            ),
            None,
        ),
        reason="manifest-version-code-invalid",
        minimum=0,
    )
    expectations = _ArtifactExpectations(
        sha256=tuple(sha_values),
        asset_sha256=tuple(asset_sha_values),
        sizes=tuple(size_values),
        validations=tuple(validations),
        package_name=package_name,
        version_code=version_code,
        version_name=version_name,
    )
    if any(_validation_failed(value) for _, value in validations):
        raise _ManifestBindingError(
            "manifest-validation-failed", expectations
        )
    if len({value for _, value in (*sha_values, *asset_sha_values)}) > 1:
        raise _ManifestBindingError(
            "manifest-integrity-conflict", expectations
        )
    if len({value for _, value in size_values}) > 1:
        raise _ManifestBindingError(
            "manifest-integrity-conflict", expectations
        )
    return expectations


def _manifest_path_hints(
    record: Mapping[str, object],
) -> tuple[tuple[str, str], ...]:
    hints: list[tuple[str, str]] = []
    for key in (
        "apk",
        "apkPath",
        "apkFile",
        "file",
        "fileName",
        "path",
        "relativePath",
        "asset_name",
    ):
        value = record.get(key)
        if isinstance(value, str) and value.strip():
            hints.append((key, value.strip()))
    resources = record.get("resources")
    if isinstance(resources, Mapping):
        value = resources.get("apk")
        if isinstance(value, str) and value.strip():
            hints.append(("resources.apk", value.strip()))
    download = record.get("download")
    if isinstance(download, Mapping):
        value = download.get("local_path")
        if isinstance(value, str) and value.strip():
            hints.append(("download.local_path", value.strip()))
    return tuple(hints)


def _manifest_url_basename_hints(
    record: Mapping[str, object],
) -> tuple[tuple[str, str], ...]:
    resources = record.get("resources")
    if not isinstance(resources, Mapping):
        return ()
    value = resources.get("apkUrl")
    if not isinstance(value, str) or not value.strip():
        return ()
    parsed = urlparse(value.strip())
    if parsed.scheme != "https" or not parsed.netloc:
        return ()
    basename = PurePosixPath(unquote(parsed.path).replace("\\", "/")).name
    if not basename or not basename.lower().endswith(".apk"):
        return ()
    return (("resources.apkUrl", basename),)


def _manifest_url_relative_hints(
    record: Mapping[str, object],
) -> tuple[str, ...]:
    resources = record.get("resources")
    if not isinstance(resources, Mapping):
        return ()
    value = resources.get("apkUrl")
    if not isinstance(value, str) or not value.strip():
        return ()
    parsed = urlparse(value.strip())
    if parsed.scheme != "https" or not parsed.netloc:
        return ()
    parts = [
        part
        for part in unquote(parsed.path).replace("\\", "/").split("/")
        if part
    ]
    if not parts or any(part in (".", "..") for part in parts):
        return ()
    if parsed.hostname == "github.com":
        for index in range(len(parts) - 5):
            if parts[index + 2 : index + 4] == ["releases", "download"]:
                return ("/".join(parts[index : index + 2] + parts[index + 4 :]),)
    if len(parts) >= 2:
        return ("/".join(parts[-2:]),)
    return ()


def _path_hint_candidates(
    hint: str,
    apk_dir: Path,
    manifest_root: Path,
) -> tuple[Path, ...]:
    has_windows_drive = bool(re.match(r"^[A-Za-z]:[\\/]", hint))
    parsed = urlparse(hint)
    if parsed.scheme and parsed.scheme != "file" and not has_windows_drive:
        return ()
    raw = unquote(parsed.path) if parsed.scheme == "file" else hint
    normalized = raw.replace("\\", "/")
    source = Path(normalized)
    candidates = (
        (source,)
        if source.is_absolute() or has_windows_drive
        else (apk_dir / normalized, manifest_root / normalized)
    )
    result: list[Path] = []
    for candidate in candidates:
        if candidate.is_file() and _is_within(candidate, apk_dir):
            resolved = candidate.resolve()
            if resolved not in result:
                result.append(resolved)
    return tuple(result)


def _identity_matches(
    expected: _ArtifactExpectations,
    actual: ApkIdentity | None,
) -> bool:
    if (
        expected.package_name is None
        and expected.version_code is None
        and expected.version_name is None
    ):
        return True
    if actual is None:
        return False
    if (
        expected.package_name is not None
        and actual.package_name != expected.package_name
    ):
        return False
    if (
        expected.version_code is not None
        and actual.version_code != expected.version_code
    ):
        return False
    if expected.version_name is not None:
        if actual.version_name is not None:
            return actual.version_name == expected.version_name
        return expected.version_code is not None
    return True


def _has_complete_identity_expectations(
    expected: _ArtifactExpectations,
) -> bool:
    return (
        expected.package_name is not None
        and expected.version_code is not None
        and expected.version_name is not None
    )


def _candidate_match(
    path: Path,
    expectations: _ArtifactExpectations,
    sha_cache: dict[Path, str],
) -> tuple[bool, ApkIdentity | None, str | None]:
    expected_digests = expectations.digests
    if expected_digests:
        actual_digest = sha_cache.get(path)
        if actual_digest is None:
            actual_digest = _sha256(path)
            sha_cache[path] = actual_digest
        if any(value != actual_digest for value in expected_digests):
            return False, None, "manifest-apk-integrity-mismatch"
    expected_sizes = expectations.expected_bytes
    if expected_sizes and any(
        value != path.stat().st_size for value in expected_sizes
    ):
        return False, None, "manifest-apk-integrity-mismatch"
    try:
        identity = _read_apk_identity(path)
    except (OSError, ValueError, zipfile.BadZipFile):
        identity = None
    if not _identity_matches(expectations, identity):
        return False, identity, "manifest-apk-identity-mismatch"
    return True, identity, None


def _binding_evidence(expectations: _ArtifactExpectations) -> tuple[str, ...]:
    evidence = [
        field for field, _ in (*expectations.sha256, *expectations.asset_sha256)
    ]
    evidence.extend(field for field, _ in expectations.sizes)
    if (
        expectations.package_name is not None
        or expectations.version_code is not None
        or expectations.version_name is not None
    ):
        evidence.append("apk.identity")
    return tuple(dict.fromkeys(evidence))


def _resolve_manifest_apk(
    record: Mapping[str, object],
    apk_dir: Path,
    manifest_root: Path,
    apk_files: Sequence[Path],
) -> _ApkBinding:
    try:
        expectations = _artifact_expectations(record)
    except _ManifestBindingError as error:
        return _ApkBinding(
            None,
            error.reason,
            expectations=error.expectations or _ArtifactExpectations(),
        )

    download = record.get("download")
    download_status = None
    if isinstance(download, Mapping):
        status = download.get("status")
        if isinstance(status, str) and status.strip():
            download_status = re.sub(r"[^A-Za-z0-9_-]+", "-", status.strip())

    direct_paths: dict[Path, list[str]] = {}
    for field, hint in _manifest_path_hints(record):
        for candidate in _path_hint_candidates(hint, apk_dir, manifest_root):
            direct_paths.setdefault(candidate, []).append(field)

    sha_cache: dict[Path, str] = {}
    if direct_paths:
        matches: list[tuple[Path, ApkIdentity | None]] = []
        failures: list[str] = []
        for path in sorted(direct_paths, key=lambda item: str(item)):
            matched, identity, failure = _candidate_match(
                path, expectations, sha_cache
            )
            if matched:
                matches.append((path, identity))
            elif failure is not None:
                failures.append(failure)
        if len(matches) == 1:
            path, identity = matches[0]
            evidence = tuple(
                dict.fromkeys(
                    (*direct_paths[path], *_binding_evidence(expectations))
                )
            )
            return _ApkBinding(
                path, None, evidence, identity, expectations
            )
        if len(matches) > 1:
            return _ApkBinding(
                None, "manifest-apk-ambiguous", expectations=expectations
            )
        reason = (
            "manifest-apk-identity-mismatch"
            if "manifest-apk-identity-mismatch" in failures
            else "manifest-apk-integrity-mismatch"
        )
        return _ApkBinding(None, reason, expectations=expectations)

    blocked_statuses = {"pending", "queued", "downloading", "failed", "error"}
    if download_status and download_status.lower() in blocked_statuses:
        return _ApkBinding(
            None,
            f"download-{download_status.lower()}",
            expectations=expectations,
        )

    url_hints = _manifest_url_basename_hints(record)
    if url_hints and _has_complete_identity_expectations(expectations):
        url_candidates = [
            path
            for path in apk_files
            if any(path.name == basename for _, basename in url_hints)
        ]
        relative_hints = _manifest_url_relative_hints(record)
        relative_candidates = [
            path
            for path in url_candidates
            if any(
                (
                    path.relative_to(apk_dir).as_posix() == hint
                    or path.relative_to(apk_dir).as_posix().endswith(
                        f"/{hint}"
                    )
                )
                for hint in relative_hints
            )
        ]
        used_relative_hint = bool(relative_candidates)
        if relative_candidates:
            url_candidates = relative_candidates
        if url_candidates:
            matches: list[tuple[Path, ApkIdentity | None]] = []
            failures: list[str] = []
            for path in url_candidates:
                matched, identity, failure = _candidate_match(
                    path, expectations, sha_cache
                )
                if matched:
                    matches.append((path, identity))
                elif failure is not None:
                    failures.append(failure)
            if matches:
                matched_digests: set[str] = set()
                for path, _ in matches:
                    digest = sha_cache.get(path)
                    if digest is None:
                        digest = _sha256(path)
                        sha_cache[path] = digest
                    matched_digests.add(digest)
                if len(matched_digests) > 1:
                    return _ApkBinding(
                        None,
                        "manifest-apk-ambiguous",
                        expectations=expectations,
                    )
                path, identity = matches[0]
                duplicate_identical = len(matches) > 1
                evidence = tuple(
                    dict.fromkeys(
                        (
                            "apk-url-basename",
                            *(field for field, _ in url_hints),
                            *(
                                ("apk-url-release-path",)
                                if used_relative_hint
                                else ()
                            ),
                            *(
                                ("duplicate-basename-identical-sha256",)
                                if duplicate_identical
                                else ()
                            ),
                            *_binding_evidence(expectations),
                        )
                    )
                )
                return _ApkBinding(
                    path, None, evidence, identity, expectations
                )
            reason = (
                "manifest-apk-identity-mismatch"
                if "manifest-apk-identity-mismatch" in failures
                else "manifest-apk-integrity-mismatch"
            )
            return _ApkBinding(None, reason, expectations=expectations)

    if expectations.digests:
        matches = []
        failures: list[str] = []
        for path in apk_files:
            matched, identity, failure = _candidate_match(
                path, expectations, sha_cache
            )
            if matched:
                matches.append((path, identity))
            elif failure is not None:
                failures.append(failure)
        if matches:
            path, identity = matches[0]
            evidence = tuple(
                dict.fromkeys(
                    (
                        "strong-sha256-fallback",
                        *_binding_evidence(expectations),
                    )
                )
            )
            return _ApkBinding(
                path, None, evidence, identity, expectations
            )
        reason = (
            "manifest-apk-identity-mismatch"
            if "manifest-apk-identity-mismatch" in failures
            else "manifest-apk-integrity-mismatch"
        )
        return _ApkBinding(
            None,
            reason,
            expectations=expectations,
        )

    if download_status:
        return _ApkBinding(
            None,
            f"download-{download_status.lower()}",
            expectations=expectations,
        )
    return _ApkBinding(
        None, "manifest-apk-missing", expectations=expectations
    )


def _plugin_inputs(
    manifest_path: Path | None,
    apk_dir: Path,
) -> tuple[
    list[tuple[dict[str, object], str, _ApkBinding]],
    list[Path],
]:
    if not apk_dir.is_dir():
        raise AuditInputError(f"{apk_dir}: APK directory does not exist")
    apk_files = sorted(
        (
            path
            for path in apk_dir.rglob("*.apk")
            if path.is_file() and _is_within(path, apk_dir)
        ),
        key=lambda path: path.relative_to(apk_dir).as_posix(),
    )
    if not apk_files:
        raise AuditInputError(f"{apk_dir}: no APK files found")
    if manifest_path is None:
        inputs = [
            (
                {
                    "name": path.stem,
                    "apk": path.relative_to(apk_dir).as_posix(),
                },
                path.relative_to(apk_dir).as_posix(),
                _ApkBinding(path, None, ("directory.apk",)),
            )
            for path in apk_files
        ]
        return inputs, []

    records = load_manifest(manifest_path)
    inputs: list[tuple[dict[str, object], str, _ApkBinding]] = []
    referenced_paths: set[Path] = set()
    for index, record in enumerate(records):
        plugin_id = _manifest_id(record, index)
        binding = _resolve_manifest_apk(
            record, apk_dir, manifest_path.parent, apk_files
        )
        if binding.path is not None:
            referenced_paths.add(binding.path)
        inputs.append((record, plugin_id, binding))
    extra = [
        path for path in apk_files if path.resolve() not in referenced_paths
    ]
    return inputs, extra


def _add_uncertainty(
    uncertainties: list[dict[str, object]],
    code: str,
    detail: str,
    evidence: Iterable[str] = (),
) -> None:
    item: dict[str, object] = {"code": code, "detail": detail}
    values = sorted(set(evidence))
    if values:
        item["evidence"] = values
    uncertainties.append(item)


def _audit_plugin(
    apk_path: Path,
    metadata: Mapping[str, object],
    universe: SymbolUniverse,
    binding: _ApkBinding,
) -> dict[str, object]:
    apk_sha256 = _sha256(apk_path)
    apk_bytes = apk_path.stat().st_size
    if any(
        value != apk_sha256 for value in binding.expectations.digests
    ) or any(
        value != apk_bytes for value in binding.expectations.expected_bytes
    ):
        raise _ManifestBindingError("manifest-apk-integrity-mismatch")
    try:
        apk_identity: ApkIdentity | None = _read_apk_identity(apk_path)
    except (OSError, ValueError, zipfile.BadZipFile):
        apk_identity = None
    if not _identity_matches(binding.expectations, apk_identity):
        raise _ManifestBindingError("manifest-apk-identity-mismatch")
    scan = parse_apk_dex(apk_path)
    plugin_universe = SymbolUniverse(
        scan.classes, universe.host, universe.android, universe.parent_prefixes
    )
    class_refs, method_refs, field_refs = external_references(scan)
    platform_metadata_classes = sorted(
        descriptor
        for descriptor in class_refs
        if descriptor.startswith(_DEX_METADATA_CLASS_PREFIX)
        and plugin_universe.lookup_class(descriptor) is None
    )
    class_refs.difference_update(platform_metadata_classes)

    missing_classes: list[str] = []
    missing_methods: list[str] = []
    missing_fields: list[str] = []
    indeterminate_methods: list[dict[str, object]] = []
    indeterminate_fields: list[dict[str, object]] = []
    access_sensitive: set[str] = set()

    resolved_classes = 0
    for descriptor in sorted(class_refs):
        resolved = plugin_universe.lookup_class(descriptor)
        if resolved is None:
            missing_classes.append(descriptor)
            continue
        info, _ = resolved
        resolved_classes += 1
        if not info.access_flags & ACC_PUBLIC:
            access_sensitive.add(f"class:{descriptor}")

    resolved_methods = 0
    for descriptor in sorted(method_refs):
        resolution = plugin_universe.resolve_method(descriptor)
        if resolution.status == "resolved":
            resolved_methods += 1
            if (
                not resolution.declaring_access & ACC_PUBLIC
                or not resolution.member_access & ACC_PUBLIC
            ):
                access_sensitive.add(f"method:{descriptor}")
        elif resolution.status == "missing-member":
            missing_methods.append(descriptor)
        elif resolution.status == "missing-class":
            missing_methods.append(descriptor)
        else:
            indeterminate_methods.append(
                {
                    "descriptor": descriptor,
                    "unresolvedAncestors": list(resolution.unresolved_ancestors),
                }
            )

    resolved_fields = 0
    for descriptor in sorted(field_refs):
        resolution = plugin_universe.resolve_field(descriptor)
        if resolution.status == "resolved":
            resolved_fields += 1
            if (
                not resolution.declaring_access & ACC_PUBLIC
                or not resolution.member_access & ACC_PUBLIC
            ):
                access_sensitive.add(f"field:{descriptor}")
        elif resolution.status == "missing-member":
            missing_fields.append(descriptor)
        elif resolution.status == "missing-class":
            missing_fields.append(descriptor)
        else:
            indeterminate_fields.append(
                {
                    "descriptor": descriptor,
                    "unresolvedAncestors": list(resolution.unresolved_ancestors),
                }
            )

    uncertainties: list[dict[str, object]] = []
    dynamic_markers = sorted(
        descriptor
        for descriptor in scan.method_refs
        if any(marker in descriptor for marker in _DYNAMIC_METHOD_MARKERS)
    )
    if dynamic_markers:
        _add_uncertainty(
            uncertainties,
            "dynamic-loading-or-reflection",
            "Dynamic class/method lookup is not resolvable from DEX reference tables.",
            dynamic_markers,
        )
    if scan.native_libraries or scan.native_methods:
        _add_uncertainty(
            uncertainties,
            "native-code-present",
            "Native methods/libraries were not loaded or ABI-checked.",
            list(scan.native_libraries) + list(scan.native_methods),
        )
    if scan.duplicate_classes:
        _add_uncertainty(
            uncertainties,
            "duplicate-class-definitions",
            "Duplicate class definitions were merged; runtime resolution may differ.",
            scan.duplicate_classes,
        )
    shadowed: list[str] = []
    for descriptor in scan.classes:
        if plugin_universe._is_parent_first(descriptor):
            parent = plugin_universe.parent_lookup(descriptor)
            if parent is not None:
                shadowed.append(descriptor)
    if shadowed:
        _add_uncertainty(
            uncertainties,
            "parent-first-shadowed-plugin-class",
            "The plugin defines a class that is also present in the parent "
            "class loader; parent-first loading selects the parent definition.",
            shadowed,
        )
    if access_sensitive:
        _add_uncertainty(
            uncertainties,
            "access-control-not-proven",
            "Existence was resolved, but non-public class/member access was not "
            "proven from the call site.",
            sorted(access_sensitive)[:50],
        )
    if platform_metadata_classes:
        _add_uncertainty(
            uncertainties,
            "dex-metadata-classes-not-in-platform-stub",
            "DEX metadata annotation classes absent from android.jar were "
            "excluded from missing-class coverage; they are not ordinary "
            "extension class references.",
            platform_metadata_classes,
        )
    if indeterminate_methods:
        _add_uncertainty(
            uncertainties,
            "indeterminate-method-inheritance",
            "A method owner or ancestor was absent from the audited class tables, "
            "so method resolution cannot be declared missing or present.",
            (item["descriptor"] for item in indeterminate_methods),
        )
    if indeterminate_fields:
        _add_uncertainty(
            uncertainties,
            "indeterminate-field-inheritance",
            "A field owner or ancestor was absent from the audited class tables, "
            "so field resolution cannot be declared missing or present.",
            (item["descriptor"] for item in indeterminate_fields),
        )

    missing_count = len(missing_classes) + len(missing_methods) + len(missing_fields)
    blocked_reasons = (
        ["parent-first-shadowed-class"] if shadowed else []
    )
    if blocked_reasons:
        status = "indeterminate"
    else:
        status = "missing-references" if missing_count else "static-resolved"
    return {
        "id": metadata.get("pkg") or metadata.get("name") or apk_path.stem,
        "metadata": dict(metadata),
        "apk": {
            "path": str(apk_path),
            "sha256": apk_sha256,
            "bytes": apk_bytes,
            "dexCount": scan.dex_count,
            "identity": (
                {
                    "packageName": apk_identity.package_name,
                    "versionCode": apk_identity.version_code,
                    "versionName": apk_identity.version_name,
                }
                if apk_identity is not None
                else None
            ),
            "bindingEvidence": list(binding.evidence),
            "expectedIntegrity": binding.expectations.report(),
        },
        "status": status,
        "blocked": bool(blocked_reasons),
        "blockedReasons": blocked_reasons,
        "staticResolutionComplete": not blocked_reasons,
        "runtimeVerified": False,
        "definitions": {
            "classes": len(scan.classes),
            "methods": sum(len(info.methods) for info in scan.classes.values()),
            "fields": sum(len(info.fields) for info in scan.classes.values()),
        },
        "coverage": {
            "classes": _coverage_bucket(
                resolved_classes, len(missing_classes), 0
            ),
            "methods": _coverage_bucket(
                resolved_methods,
                len(missing_methods),
                len(indeterminate_methods),
            ),
            "fields": _coverage_bucket(
                resolved_fields,
                len(missing_fields),
                len(indeterminate_fields),
            ),
            "combined": _coverage_bucket(
                resolved_classes + resolved_methods + resolved_fields,
                missing_count,
                len(indeterminate_methods) + len(indeterminate_fields),
            ),
        },
        "missing": {
            "classes": [{"descriptor": value} for value in missing_classes],
            "methods": [{"descriptor": value} for value in missing_methods],
            "fields": [{"descriptor": value} for value in missing_fields],
            "indeterminateMethods": indeterminate_methods,
            "indeterminateFields": indeterminate_fields,
        },
        "ignoredPlatformMetadataClasses": platform_metadata_classes,
        "uncertainties": uncertainties,
    }


def build_report(
    *,
    manifest_path: Path | None,
    apk_dir: Path,
    host_apk: Path,
    android_jar: Path,
    mihon_host_source: Path,
) -> dict[str, object]:
    apk_dir = apk_dir.resolve()
    host_apk = host_apk.resolve()
    android_jar = android_jar.resolve()
    mihon_host_source = mihon_host_source.resolve()
    if manifest_path is not None:
        manifest_path = manifest_path.resolve()
    if not host_apk.is_file():
        raise AuditInputError(f"{host_apk}: host APK does not exist")
    if not android_jar.is_file():
        raise AuditInputError(f"{android_jar}: android.jar does not exist")
    if not mihon_host_source.is_file():
        raise AuditInputError(f"{mihon_host_source}: MihonHost source does not exist")

    try:
        prefixes = parse_parent_first_prefixes(
            mihon_host_source.read_text(encoding="utf-8")
        )
    except (OSError, UnicodeError) as error:
        raise AuditInputError(
            f"{mihon_host_source}: cannot read MihonHost source: {error}"
        ) from error

    inputs, extra_apks = _plugin_inputs(manifest_path, apk_dir)
    warnings = (
        manifest_warnings([record for record, _, _ in inputs])
        if manifest_path is not None
        else []
    )
    host_scan = parse_apk_dex(host_apk)
    android_classes = parse_android_jar(android_jar)
    universe = SymbolUniverse({}, host_scan.classes, android_classes, prefixes)

    plugins: list[dict[str, object]] = []
    not_audited: list[dict[str, object]] = []
    for record, plugin_id, binding in inputs:
        metadata = _selected_metadata(record)
        if binding.path is None:
            not_audited.append(
                {
                    "id": plugin_id,
                    "reason": binding.error or "manifest-apk-missing",
                    "metadata": metadata,
                    "expectedIntegrity": binding.expectations.report(),
                }
            )
            continue
        try:
            plugins.append(
                _audit_plugin(binding.path, metadata, universe, binding)
            )
        except _ManifestBindingError as failure:
            not_audited.append(
                {
                    "id": plugin_id,
                    "reason": failure.reason,
                    "apkPath": str(binding.path),
                    "metadata": metadata,
                    "expectedIntegrity": binding.expectations.report(),
                }
            )
        except (OSError, zipfile.BadZipFile, DexFormatError, ValueError) as failure:
            not_audited.append(
                {
                    "id": plugin_id,
                    "reason": "apk-parse-failed",
                    "apkPath": str(binding.path),
                    "metadata": metadata,
                    "expectedIntegrity": binding.expectations.report(),
                    "error": f"{failure.__class__.__name__}: {failure}",
                }
            )

    for apk_path in extra_apks:
        not_audited.append(
            {
                "id": apk_path.relative_to(apk_dir).as_posix(),
                "reason": "apk-not-referenced-by-manifest",
                "apkPath": str(apk_path),
            }
        )

    totals = {"resolved": 0, "missing": 0, "indeterminate": 0}
    missing_by_kind = {"classes": 0, "methods": 0, "fields": 0}
    for plugin in plugins:
        combined = plugin["coverage"]["combined"]  # type: ignore[index]
        totals["resolved"] += combined["resolved"]
        totals["missing"] += combined["missing"]
        totals["indeterminate"] += combined["indeterminate"]
        for kind in missing_by_kind:
            missing_by_kind[kind] += plugin["coverage"][kind]["missing"]  # type: ignore[index]

    total_references = sum(totals.values())
    expected_plugins = len(inputs)
    audited_plugins = len(plugins)
    missing_plugins = sum(
        1 for plugin in plugins if plugin["status"] == "missing-references"
    )
    indeterminate_plugins = sum(
        1 for plugin in plugins if plugin["status"] == "indeterminate"
    )
    report = {
        "schemaVersion": 1,
        "format": "triomi-mihon-static-reference-audit",
        "runtimeStatus": "not-run",
        "runtimeVerified": False,
        "claim": (
            "Static reference resolution only. Static resolution is not runtime "
            "success and does not prove search, loading, network, image, native, "
            "reflective, or behavioral compatibility."
        ),
        "manifestWarnings": warnings,
        "inputs": {
            "manifest": str(manifest_path) if manifest_path is not None else None,
            "apkDirectory": str(apk_dir),
            "hostApk": {
                "path": str(host_apk),
                "sha256": _sha256(host_apk),
                "bytes": host_apk.stat().st_size,
                "dexCount": host_scan.dex_count,
                "classes": len(host_scan.classes),
                "methods": sum(
                    len(info.methods) for info in host_scan.classes.values()
                ),
                "fields": sum(
                    len(info.fields) for info in host_scan.classes.values()
                ),
            },
            "androidJar": {
                "path": str(android_jar),
                "sha256": _sha256(android_jar),
                "bytes": android_jar.stat().st_size,
                "classes": len(android_classes),
            },
            "mihonHostSource": {
                "path": str(mihon_host_source),
                "sha256": _sha256(mihon_host_source),
                "parentFirstPrefixes": list(prefixes),
            },
        },
        "summary": {
            "expectedPluginEntries": expected_plugins,
            "pluginsAudited": audited_plugins,
            "pluginsWithMissingReferences": missing_plugins,
            "pluginsIndeterminate": indeterminate_plugins,
            "notAudited": len(not_audited),
            "pluginAuditRatio": _ratio(audited_plugins, expected_plugins),
            "referenceCoverage": _coverage_bucket(
                totals["resolved"], totals["missing"], totals["indeterminate"]
            ),
            "missingByKind": missing_by_kind,
        },
        "plugins": plugins,
        "notAudited": not_audited,
        "globalUncertainties": [
            {
                "code": "static-reference-audit-only",
                "detail": (
                    "DEX class/method/field tables cannot establish runtime "
                    "linkage under reflection, JNI, generated code, resources, "
                    "services, network responses, or plugin business logic."
                ),
            },
            {
                "code": "android-jar-is-a-compile-time-stub",
                "detail": (
                    "android.jar supplied platform class/member descriptors; "
                    "presence there does not prove device-runtime availability."
                ),
            },
            {
                "code": "access-and-invoke-semantics-not-proven",
                "detail": (
                    "Member existence and basic inheritance were checked. Caller-"
                    "specific access, invoke kind, verifier behavior, and default-"
                    "method linkage were not executed."
                ),
            },
            {
                "code": "dex-metadata-annotations-not-classpath-audited",
                "detail": (
                    "dalvik.annotation metadata descriptors absent from "
                    "android.jar are reported separately from ordinary "
                    "missing classes."
                ),
            },
        ],
    }
    if warnings:
        report["globalUncertainties"].append(  # type: ignore[union-attr]
            {
                "code": "manifest-coverage-may-be-incomplete",
                "detail": (
                    "The manifest contains only status-placeholder entries; "
                    "an all-plugin compatibility conclusion must wait for a "
                    "complete frozen inventory."
                ),
            }
        )
    return report


def _write_report(report: Mapping[str, object], output: str) -> None:
    payload = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if output == "-":
        sys.stdout.write(payload)
        return
    destination = Path(output)
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(payload, encoding="utf-8")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--manifest",
        type=Path,
        help=(
            "Frozen JSON index, snapshot extensionList, or compat-audit "
            "apk-manifest.jsonl; omit to audit every APK in --apk-dir"
        ),
    )
    parser.add_argument("--apk-dir", required=True, type=Path)
    parser.add_argument("--host-apk", required=True, type=Path)
    parser.add_argument("--android-jar", required=True, type=Path)
    parser.add_argument(
        "--mihon-host-source",
        type=Path,
        default=DEFAULT_MIHON_HOST_SOURCE,
        help="MihonHost.kt used to read the actual parent-first prefixes",
    )
    parser.add_argument("--output", default="-", help="JSON output path or - for stdout")
    args = parser.parse_args(argv)

    try:
        report = build_report(
            manifest_path=args.manifest,
            apk_dir=args.apk_dir,
            host_apk=args.host_apk,
            android_jar=args.android_jar,
            mihon_host_source=args.mihon_host_source,
        )
    except (AuditInputError, OSError, ClassFileFormatError, DexFormatError) as error:
        print(f"Extension audit error: {error}", file=sys.stderr)
        return 2

    _write_report(report, args.output)
    summary = report["summary"]  # type: ignore[index]
    if (
        summary["pluginsWithMissingReferences"]
        or summary["pluginsIndeterminate"]
        or summary["notAudited"]
    ):
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
