#!/usr/bin/env python3
"""Check Mihon extension ABI descriptors against an APK's public DEX tables."""

from __future__ import annotations

import argparse
import json
import re
import struct
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence


NO_INDEX = 0xFFFFFFFF
ACC_PUBLIC = 0x0001
ACC_PRIVATE = 0x0002
ACC_PROTECTED = 0x0004
VISIBLE_ACCESS = ACC_PUBLIC | ACC_PROTECTED

_CLASS = re.compile(r"^L[^;]+;$")
_MEMBER = re.compile(r"^(L[^;]+;)->(.+)$")
_METHOD = re.compile(r"^([^(:]+)(\([^)]*\))(.+)$")
_FIELD = re.compile(r"^([^:]+):(.+)$")
_DEX_NAME = re.compile(r"^classes(?:(\d+))?\.dex$")


class DexFormatError(ValueError):
    """The DEX payload does not contain a table layout the gate can read."""


@dataclass(frozen=True)
class MemberInfo:
    name: str
    proto: str
    access_flags: int


@dataclass(frozen=True)
class ClassInfo:
    descriptor: str
    access_flags: int
    superclass: str | None
    interfaces: tuple[str, ...]
    methods: frozenset[str]
    fields: frozenset[str]


@dataclass
class AbiIndex:
    classes: dict[str, ClassInfo]
    dex_count: int

    @property
    def class_count(self) -> int:
        return len(self.classes)

    @property
    def member_count(self) -> int:
        return sum(len(item.methods) + len(item.fields) for item in self.classes.values())

    def has_member(self, descriptor: str) -> bool:
        parsed = _parse_member_descriptor(descriptor)
        if parsed is None:
            return False
        owner, name, tail, is_method = parsed
        owner_info = self.classes.get(owner)
        if owner_info is None:
            return False
        if not is_method:
            return tail in owner_info.fields

        if name == "<init>":
            return tail in owner_info.methods

        pending = [owner]
        visited: set[str] = set()
        while pending:
            current = pending.pop()
            if current in visited:
                continue
            visited.add(current)
            info = self.classes.get(current)
            if info is None:
                continue
            if tail in info.methods:
                return True
            if info.superclass is not None:
                pending.append(info.superclass)
            pending.extend(info.interfaces)
        return False


class _DexReader:
    def __init__(self, data: bytes, source: str) -> None:
        self.data = data
        self.source = source
        if len(data) < 112 or not data.startswith(b"dex\n"):
            raise DexFormatError(f"{source}: not a standard DEX file")
        self.endian = self.u32(40)
        if self.endian == 0x78563412:
            raise DexFormatError(f"{source}: reverse-endian DEX is unsupported")
        if self.endian != 0x12345678:
            raise DexFormatError(f"{source}: invalid endian tag")
        if self.u32(36) < 112:
            raise DexFormatError(f"{source}: invalid header size")

        self.string_ids = self._table(56, 4)
        self.type_ids = self._table(64, 4)
        self.proto_ids = self._table(72, 12)
        self.field_ids = self._table(80, 8)
        self.method_ids = self._table(88, 8)
        self.class_defs = self._table(96, 32)

    def _table(self, count_offset: int, row_size: int) -> list[int]:
        count = self.u32(count_offset)
        offset = self.u32(count_offset + 4)
        self._check(offset, count * row_size)
        return [offset + index * row_size for index in range(count)]

    def _check(self, offset: int, size: int) -> None:
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise DexFormatError(f"{self.source}: table points outside file")

    def u16(self, offset: int) -> int:
        self._check(offset, 2)
        return struct.unpack_from("<H", self.data, offset)[0]

    def u32(self, offset: int) -> int:
        self._check(offset, 4)
        return struct.unpack_from("<I", self.data, offset)[0]

    def uleb(self, offset: int) -> tuple[int, int]:
        value = 0
        shift = 0
        for _ in range(5):
            self._check(offset, 1)
            byte = self.data[offset]
            offset += 1
            value |= (byte & 0x7F) << shift
            if not byte & 0x80:
                return value, offset
            shift += 7
        raise DexFormatError(f"{self.source}: invalid ULEB128 value")

    def string(self, index: int) -> str:
        if not 0 <= index < len(self.string_ids):
            raise DexFormatError(f"{self.source}: string index out of range")
        offset = self.u32(self.string_ids[index])
        _, offset = self.uleb(offset)
        end = self.data.find(b"\x00", offset)
        if end < 0:
            raise DexFormatError(f"{self.source}: unterminated string")
        return _decode_mutf8(self.data[offset:end], self.source)

    def type(self, index: int) -> str:
        if not 0 <= index < len(self.type_ids):
            raise DexFormatError(f"{self.source}: type index out of range")
        return self.string(self.u32(self.type_ids[index]))

    def type_list(self, offset: int) -> tuple[str, ...]:
        if offset == 0:
            return ()
        count = self.u32(offset)
        self._check(offset + 4, count * 2)
        return tuple(self.type(self.u16(offset + 4 + index * 2)) for index in range(count))

    def proto(self, index: int) -> str:
        if not 0 <= index < len(self.proto_ids):
            raise DexFormatError(f"{self.source}: proto index out of range")
        offset = self.proto_ids[index]
        return_type = self.type(self.u32(offset + 4))
        parameters = self.type_list(self.u32(offset + 8))
        return "(" + "".join(parameters) + ")" + return_type

    def field_descriptor(self, index: int) -> str:
        if not 0 <= index < len(self.field_ids):
            raise DexFormatError(f"{self.source}: field index out of range")
        offset = self.field_ids[index]
        return f"{self.type(self.u16(offset))}->{self.string(self.u32(offset + 4))}:{self.type(self.u16(offset + 2))}"

    def method_parts(self, index: int) -> tuple[str, str, str]:
        if not 0 <= index < len(self.method_ids):
            raise DexFormatError(f"{self.source}: method index out of range")
        offset = self.method_ids[index]
        return (
            self.type(self.u16(offset)),
            self.string(self.u32(offset + 4)),
            self.proto(self.u16(offset + 2)),
        )

    def decode(self) -> dict[str, ClassInfo]:
        classes: dict[str, ClassInfo] = {}
        for class_offset in self.class_defs:
            class_index = self.u32(class_offset)
            access_flags = self.u32(class_offset + 4)
            if not access_flags & VISIBLE_ACCESS:
                continue
            descriptor = self.type(class_index)
            superclass_index = self.u32(class_offset + 8)
            superclass = None if superclass_index == NO_INDEX else self.type(superclass_index)
            interfaces = self.type_list(self.u32(class_offset + 12))
            methods: set[str] = set()
            fields: set[str] = set()
            class_data_offset = self.u32(class_offset + 24)
            if class_data_offset:
                self._read_class_data(
                    class_data_offset,
                    methods,
                    fields,
                )
            classes[descriptor] = ClassInfo(
                descriptor=descriptor,
                access_flags=access_flags,
                superclass=superclass,
                interfaces=interfaces,
                methods=frozenset(methods),
                fields=frozenset(fields),
            )
        return classes

    def _read_class_data(
        self,
        offset: int,
        methods: set[str],
        fields: set[str],
    ) -> None:
        static_fields, offset = self.uleb(offset)
        instance_fields, offset = self.uleb(offset)
        direct_methods, offset = self.uleb(offset)
        virtual_methods, offset = self.uleb(offset)

        for count in (static_fields, instance_fields):
            field_index = 0
            for _ in range(count):
                delta, offset = self.uleb(offset)
                access_flags, offset = self.uleb(offset)
                field_index += delta
                if access_flags & VISIBLE_ACCESS:
                    descriptor = self.field_descriptor(field_index)
                    fields.add(descriptor.split("->", 1)[1])

        for count in (direct_methods, virtual_methods):
            method_index = 0
            for _ in range(count):
                delta, offset = self.uleb(offset)
                access_flags, offset = self.uleb(offset)
                _, offset = self.uleb(offset)
                method_index += delta
                if access_flags & VISIBLE_ACCESS:
                    _, name, proto = self.method_parts(method_index)
                    methods.add(name + proto)


def _decode_mutf8(raw: bytes, source: str) -> str:
    units: list[int] = []
    index = 0
    while index < len(raw):
        first = raw[index]
        index += 1
        if first < 0x80:
            units.append(first)
        elif first & 0xE0 == 0xC0:
            if index >= len(raw) or raw[index] & 0xC0 != 0x80:
                raise DexFormatError(f"{source}: invalid MUTF-8")
            units.append(((first & 0x1F) << 6) | (raw[index] & 0x3F))
            index += 1
        elif first & 0xF0 == 0xE0:
            if index + 1 >= len(raw) or raw[index] & 0xC0 != 0x80 or raw[index + 1] & 0xC0 != 0x80:
                raise DexFormatError(f"{source}: invalid MUTF-8")
            units.append(
                ((first & 0x0F) << 12)
                | ((raw[index] & 0x3F) << 6)
                | (raw[index + 1] & 0x3F)
            )
            index += 2
        else:
            raise DexFormatError(f"{source}: unsupported MUTF-8 lead byte")
    return "".join(chr(unit) for unit in units)


def parse_dex(data: bytes, source: str = "<memory>") -> dict[str, ClassInfo]:
    return _DexReader(data, source).decode()


def parse_apk(apk_path: Path) -> AbiIndex:
    try:
        archive = zipfile.ZipFile(apk_path)
    except (OSError, zipfile.BadZipFile) as error:
        raise DexFormatError(f"{apk_path}: cannot read APK: {error}") from error

    with archive:
        dex_names: list[str] = []
        for name in archive.namelist():
            match = _DEX_NAME.fullmatch(name)
            if match:
                dex_names.append(name)
        dex_names.sort(key=_dex_sort_key)
        if not dex_names:
            raise DexFormatError(f"{apk_path}: APK contains no classes*.dex")

        merged: dict[str, ClassInfo] = {}
        for name in dex_names:
            for descriptor, info in parse_dex(archive.read(name), f"{apk_path}!{name}").items():
                previous = merged.get(descriptor)
                if previous is None:
                    merged[descriptor] = info
                    continue
                merged[descriptor] = ClassInfo(
                    descriptor=descriptor,
                    access_flags=previous.access_flags | info.access_flags,
                    superclass=previous.superclass or info.superclass,
                    interfaces=tuple(dict.fromkeys(previous.interfaces + info.interfaces)),
                    methods=previous.methods | info.methods,
                    fields=previous.fields | info.fields,
                )
    return AbiIndex(classes=merged, dex_count=len(dex_names))


def _dex_sort_key(name: str) -> int:
    match = _DEX_NAME.fullmatch(name)
    if match is None:
        return sys.maxsize
    return int(match.group(1) or "1")


def _parse_member_descriptor(
    descriptor: str,
) -> tuple[str, str, str, bool] | None:
    if _CLASS.fullmatch(descriptor):
        return None
    match = _MEMBER.fullmatch(descriptor)
    if match is None:
        return None
    owner, member = match.groups()
    method = _METHOD.fullmatch(member)
    if method is not None:
        name, proto, returns = method.groups()
        return owner, name, name + proto + returns, True
    field = _FIELD.fullmatch(member)
    if field is not None:
        name, field_type = field.groups()
        return owner, name, name + ":" + field_type, False
    return None


def load_manifest(path: Path) -> list[str]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"{path}: cannot read manifest: {error}") from error
    if not isinstance(payload, dict) or payload.get("schemaVersion") != 1:
        raise ValueError(f"{path}: schemaVersion must be 1")
    required = payload.get("required")
    if not isinstance(required, list) or not required:
        raise ValueError(f"{path}: required must be a non-empty array")
    if not all(isinstance(item, str) and item.strip() for item in required):
        raise ValueError(f"{path}: every required entry must be a non-empty string")
    if len(set(required)) != len(required):
        raise ValueError(f"{path}: required contains duplicates")
    return required


def missing_descriptors(index: AbiIndex, required: Iterable[str]) -> list[str]:
    missing: list[str] = []
    for descriptor in required:
        if _CLASS.fullmatch(descriptor):
            present = descriptor in index.classes
        else:
            present = index.has_member(descriptor)
        if not present:
            missing.append(descriptor)
    return missing


def check_apk(
    apk_path: Path,
    required: Sequence[str],
) -> tuple[AbiIndex, list[str]]:
    index = parse_apk(apk_path)
    return index, missing_descriptors(index, required)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Fail when an APK no longer exposes the pinned Mihon source-api ABI.",
    )
    parser.add_argument("--apk", required=True, type=Path)
    parser.add_argument(
        "--manifest",
        type=Path,
        default=Path(__file__).with_name("mihon_source_api_abi.json"),
    )
    args = parser.parse_args(argv)

    try:
        required = load_manifest(args.manifest)
        index, missing = check_apk(args.apk, required)
    except (DexFormatError, OSError, ValueError) as error:
        print(f"ABI check error: {error}", file=sys.stderr)
        return 2

    if missing:
        print(
            f"Mihon ABI missing {len(missing)}/{len(required)} descriptor(s):",
            file=sys.stderr,
        )
        for descriptor in missing:
            print(f"  {descriptor}", file=sys.stderr)
        return 1

    print(
        "Mihon ABI OK: "
        f"{len(required)} descriptors across {index.dex_count} DEX files "
        f"({index.class_count} public/protected classes, "
        f"{index.member_count} visible members)."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
