from __future__ import annotations

import struct
import unittest
from dataclasses import dataclass
from pathlib import Path

from tools.check_mihon_abi import (
    ACC_PRIVATE,
    ACC_PROTECTED,
    ACC_PUBLIC,
    AbiIndex,
    missing_descriptors,
    parse_dex,
)
from tools.check_mihon_abi import load_manifest


@dataclass(frozen=True)
class _Method:
    name: str
    parameters: tuple[str, ...]
    returns: str
    access: int


@dataclass(frozen=True)
class _Field:
    name: str
    field_type: str
    access: int


@dataclass(frozen=True)
class _Class:
    descriptor: str
    access: int
    superclass: str | None = None
    interfaces: tuple[str, ...] = ()
    methods: tuple[_Method, ...] = ()
    fields: tuple[_Field, ...] = ()


def _uleb(value: int) -> bytes:
    encoded = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            encoded.append(byte | 0x80)
        else:
            encoded.append(byte)
            return bytes(encoded)


def _align(buffer: bytearray, alignment: int = 4) -> None:
    while len(buffer) % alignment:
        buffer.append(0)


def _shorty(proto: tuple[tuple[str, ...], str]) -> str:
    parameters, returns = proto
    return returns[0] + "".join(item[0] for item in parameters)


def _synthetic_dex(classes: list[_Class]) -> bytes:
    class_descriptors = {item.descriptor for item in classes}
    protos = {
        (method.parameters, method.returns)
        for item in classes
        for method in item.methods
    }
    field_types = {
        field.field_type
        for item in classes
        for field in item.fields
    }
    type_descriptors = set(class_descriptors) | field_types
    for item in classes:
        if item.superclass is not None:
            type_descriptors.add(item.superclass)
        type_descriptors.update(item.interfaces)
    for parameters, returns in protos:
        type_descriptors.update(parameters)
        type_descriptors.add(returns)

    strings = set(type_descriptors)
    strings.update(method.name for item in classes for method in item.methods)
    strings.update(field.name for item in classes for field in item.fields)
    strings.update(_shorty(proto) for proto in protos)
    ordered_strings = sorted(strings)
    ordered_types = sorted(type_descriptors)
    ordered_protos = sorted(protos)
    string_index = {value: index for index, value in enumerate(ordered_strings)}
    type_index = {value: index for index, value in enumerate(ordered_types)}
    proto_index = {value: index for index, value in enumerate(ordered_protos)}

    field_specs = sorted(
        (
            item.descriptor,
            field.name,
            field.field_type,
            field.access,
        )
        for item in classes
        for field in item.fields
    )
    field_index = {
        (owner, name, field_type): index
        for index, (owner, name, field_type, _) in enumerate(field_specs)
    }
    method_specs = sorted(
        (
            item.descriptor,
            method.name,
            method.parameters,
            method.returns,
            method.access,
        )
        for item in classes
        for method in item.methods
    )
    method_index = {
        (owner, name, parameters, returns): index
        for index, (owner, name, parameters, returns, _) in enumerate(method_specs)
    }
    ordered_classes = sorted(classes, key=lambda item: type_index[item.descriptor])

    tables_size = (
        len(ordered_strings) * 4
        + len(ordered_types) * 4
        + len(ordered_protos) * 12
        + len(field_specs) * 8
        + len(method_specs) * 8
        + len(ordered_classes) * 32
    )
    data = bytearray(112 + tables_size)
    string_ids_off = 112
    type_ids_off = string_ids_off + len(ordered_strings) * 4
    proto_ids_off = type_ids_off + len(ordered_types) * 4
    field_ids_off = proto_ids_off + len(ordered_protos) * 12
    method_ids_off = field_ids_off + len(field_specs) * 8
    class_defs_off = method_ids_off + len(method_specs) * 8
    data_off = class_defs_off + len(ordered_classes) * 32

    for index, value in enumerate(ordered_strings):
        _align(data)
        struct.pack_into("<I", data, string_ids_off + index * 4, len(data))
        data.extend(_uleb(len(value)))
        data.extend(value.encode("ascii"))
        data.append(0)

    type_list_offsets: dict[tuple[str, ...], int] = {}

    def add_type_list(values: tuple[str, ...]) -> int:
        if not values:
            return 0
        existing = type_list_offsets.get(values)
        if existing is not None:
            return existing
        _align(data)
        offset = len(data)
        data.extend(struct.pack("<I", len(values)))
        for value in values:
            data.extend(struct.pack("<H", type_index[value]))
        type_list_offsets[values] = offset
        return offset

    for index, value in enumerate(ordered_types):
        struct.pack_into("<I", data, type_ids_off + index * 4, string_index[value])

    for index, (parameters, returns) in enumerate(ordered_protos):
        offset = proto_ids_off + index * 12
        struct.pack_into("<I", data, offset, string_index[_shorty((parameters, returns))])
        struct.pack_into("<I", data, offset + 4, type_index[returns])
        struct.pack_into("<I", data, offset + 8, add_type_list(parameters))

    for index, (owner, name, field_type, _) in enumerate(field_specs):
        offset = field_ids_off + index * 8
        struct.pack_into("<HH", data, offset, type_index[owner], type_index[field_type])
        struct.pack_into("<I", data, offset + 4, string_index[name])

    for index, (owner, name, parameters, returns, _) in enumerate(method_specs):
        offset = method_ids_off + index * 8
        struct.pack_into("<HH", data, offset, type_index[owner], proto_index[(parameters, returns)])
        struct.pack_into("<I", data, offset + 4, string_index[name])

    for class_offset_index, item in enumerate(ordered_classes):
        _align(data)
        class_data_offset = len(data)
        static_fields = [field for field in item.fields if field.access & 0x0008]
        instance_fields = [field for field in item.fields if not field.access & 0x0008]
        direct_methods = [
            method
            for method in item.methods
            if method.name == "<init>" or method.access & (0x0002 | 0x0008)
        ]
        virtual_methods = [method for method in item.methods if method not in direct_methods]
        data.extend(_uleb(len(static_fields)))
        data.extend(_uleb(len(instance_fields)))
        data.extend(_uleb(len(direct_methods)))
        data.extend(_uleb(len(virtual_methods)))

        for group in (static_fields, instance_fields):
            previous = 0
            for field in sorted(group, key=lambda value: field_index[(item.descriptor, value.name, value.field_type)]):
                current = field_index[(item.descriptor, field.name, field.field_type)]
                data.extend(_uleb(current - previous))
                data.extend(_uleb(field.access))
                previous = current
        for group in (direct_methods, virtual_methods):
            previous = 0
            for method in sorted(
                group,
                key=lambda value: method_index[
                    (item.descriptor, value.name, value.parameters, value.returns)
                ],
            ):
                current = method_index[
                    (item.descriptor, method.name, method.parameters, method.returns)
                ]
                data.extend(_uleb(current - previous))
                data.extend(_uleb(method.access))
                data.extend(_uleb(0))
                previous = current

        offset = class_defs_off + class_offset_index * 32
        struct.pack_into("<I", data, offset, type_index[item.descriptor])
        struct.pack_into("<I", data, offset + 4, item.access)
        superclass = 0xFFFFFFFF if item.superclass is None else type_index[item.superclass]
        struct.pack_into("<I", data, offset + 8, superclass)
        struct.pack_into("<I", data, offset + 12, add_type_list(item.interfaces))
        struct.pack_into("<I", data, offset + 16, 0xFFFFFFFF)
        struct.pack_into("<I", data, offset + 20, 0)
        struct.pack_into("<I", data, offset + 24, class_data_offset)
        struct.pack_into("<I", data, offset + 28, 0)

    data[0:8] = b"dex\n035\x00"
    struct.pack_into("<I", data, 32, len(data))
    struct.pack_into("<I", data, 36, 112)
    struct.pack_into("<I", data, 40, 0x12345678)
    struct.pack_into("<II", data, 44, 0, 0)
    struct.pack_into("<I", data, 52, 0)
    struct.pack_into("<II", data, 56, len(ordered_strings), string_ids_off)
    struct.pack_into("<II", data, 64, len(ordered_types), type_ids_off)
    struct.pack_into("<II", data, 72, len(ordered_protos), proto_ids_off)
    struct.pack_into("<II", data, 80, len(field_specs), field_ids_off)
    struct.pack_into("<II", data, 88, len(method_specs), method_ids_off)
    struct.pack_into("<II", data, 96, len(ordered_classes), class_defs_off)
    struct.pack_into("<II", data, 104, len(data) - data_off, data_off)
    return bytes(data)


class CheckMihonAbiTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        classes = [
            _Class(
                descriptor="LBase;",
                access=ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("<init>", (), "V", ACC_PUBLIC),
                    _Method("baseOnly", (), "V", ACC_PUBLIC),
                    _Method("visibleProtected", (), "V", ACC_PROTECTED),
                    _Method("hiddenPrivate", (), "V", ACC_PRIVATE),
                ),
                fields=(
                    _Field("value", "I", ACC_PUBLIC),
                    _Field("secret", "I", ACC_PRIVATE),
                ),
            ),
            _Class(
                descriptor="LChild;",
                access=ACC_PUBLIC,
                superclass="LBase;",
                interfaces=("LIface;",),
                methods=(
                    _Method("<init>", (), "V", ACC_PUBLIC),
                    _Method("childOnly", (), "V", ACC_PUBLIC),
                ),
            ),
            _Class(
                descriptor="LIface;",
                access=ACC_PUBLIC | 0x0200,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("interfaceOnly", (), "V", ACC_PUBLIC | 0x0400),
                ),
            ),
            _Class(
                descriptor="LPrivateClass;",
                access=ACC_PRIVATE,
                superclass="Ljava/lang/Object;",
            ),
            _Class(
                descriptor="LPackageClass;",
                access=0,
                superclass="Ljava/lang/Object;",
            ),
        ]
        cls.index = AbiIndex(classes=parse_dex(_synthetic_dex(classes)), dex_count=1)

    def test_collects_only_public_and_protected_classes(self) -> None:
        self.assertEqual({"LBase;", "LChild;", "LIface;"}, set(self.index.classes))
        self.assertEqual(3, self.index.class_count)

    def test_collects_only_visible_members(self) -> None:
        base = self.index.classes["LBase;"]
        self.assertIn("baseOnly()V", base.methods)
        self.assertIn("visibleProtected()V", base.methods)
        self.assertNotIn("hiddenPrivate()V", base.methods)
        self.assertIn("value:I", base.fields)
        self.assertNotIn("secret:I", base.fields)

    def test_methods_are_inherited_from_superclass_and_interfaces(self) -> None:
        self.assertTrue(self.index.has_member("LChild;->baseOnly()V"))
        self.assertTrue(self.index.has_member("LChild;->interfaceOnly()V"))
        self.assertFalse(self.index.has_member("LChild;->hiddenPrivate()V"))
        self.assertFalse(self.index.has_member("LBase;->childOnly()V"))

    def test_constructors_are_not_inherited(self) -> None:
        self.assertTrue(self.index.has_member("LChild;-><init>()V"))
        self.assertFalse(self.index.has_member("LChild;-><init>(I)V"))
        self.assertTrue(self.index.has_member("LBase;-><init>()V"))

    def test_field_lookup_is_exact_to_owner(self) -> None:
        self.assertTrue(self.index.has_member("LBase;->value:I"))
        self.assertFalse(self.index.has_member("LChild;->value:I"))
        self.assertFalse(self.index.has_member("LBase;->missing:I"))

    def test_missing_descriptors_preserve_manifest_order(self) -> None:
        required = [
            "LChild;",
            "LChild;->baseOnly()V",
            "LChild;-><init>(I)V",
            "LBase;->value:I",
            "LPrivateClass;",
        ]
        self.assertEqual(
            ["LChild;-><init>(I)V", "LPrivateClass;"],
            missing_descriptors(self.index, required),
        )

    def test_manifest_pins_required_contracts_without_duplicate_descriptors(self) -> None:
        required = load_manifest(Path(__file__).with_name("mihon_source_api_abi.json"))
        self.assertGreaterEqual(len(required), 20)
        self.assertEqual(len(required), len(set(required)))
        self.assertIn("Leu/kanade/tachiyomi/network/HttpException;->getCode()I", required)
        self.assertIn("Lapp/cash/quickjs/QuickJs;->compile(Ljava/lang/String;Ljava/lang/String;)[B", required)
        self.assertIn("Lkotlinx/serialization/protobuf/ProtoIntegerType;->SIGNED:Lkotlinx/serialization/protobuf/ProtoIntegerType;", required)
        self.assertIn("Ltachiyomi/decoder/ImageDecoder;->recycle()V", required)
        self.assertEqual(30, sum(item.startswith("Lokhttp3/Interceptor$Chain;") for item in required))
        self.assertIn(
            "Lkotlinx/coroutines/BuildersKt;->runBlockingK$default(Lkotlin/coroutines/CoroutineContext;Lkotlin/jvm/functions/Function2;ILjava/lang/Object;)Ljava/lang/Object;",
            required,
        )
        self.assertIn(
            "Leu/kanade/tachiyomi/source/model/Page$Companion;->serializer()Lkotlinx/serialization/KSerializer;",
            required,
        )
        self.assertIn(
            "Leu/kanade/tachiyomi/source/PagePreviewPage$Companion;->serializer()Lkotlinx/serialization/KSerializer;",
            required,
        )
        self.assertIn(
            "Leu/kanade/tachiyomi/util/JsoupExtensionsKt;->asJsoup$default(Lokhttp3/Response;Ljava/lang/String;ILjava/lang/Object;)Lorg/jsoup/nodes/Document;",
            required,
        )


if __name__ == "__main__":
    unittest.main()
