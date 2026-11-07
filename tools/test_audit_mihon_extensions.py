from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import shutil
import struct
import tempfile
import unittest
import zipfile

from tools import audit_mihon_extensions as audit


@dataclass(frozen=True)
class _Method:
    name: str
    parameters: tuple[str, ...]
    returns: str
    access: int = 0x0001


@dataclass(frozen=True)
class _Field:
    name: str
    field_type: str
    access: int = 0x0001


@dataclass(frozen=True)
class _Class:
    descriptor: str
    access: int
    superclass: str | None = None
    interfaces: tuple[str, ...] = ()
    methods: tuple[_Method, ...] = ()
    fields: tuple[_Field, ...] = ()


@dataclass(frozen=True)
class _MethodRef:
    owner: str
    name: str
    parameters: tuple[str, ...]
    returns: str


@dataclass(frozen=True)
class _FieldRef:
    owner: str
    name: str
    field_type: str


def _uleb(value: int) -> bytes:
    output = bytearray()
    while True:
        byte = value & 0x7F
        value >>= 7
        if value:
            output.append(byte | 0x80)
        else:
            output.append(byte)
            return bytes(output)


def _align(buffer: bytearray, alignment: int = 4) -> None:
    while len(buffer) % alignment:
        buffer.append(0)


def _shorty_type(descriptor: str) -> str:
    return "L" if descriptor.startswith(("L", "[")) else descriptor


def _shorty(parameters: tuple[str, ...], returns: str) -> str:
    return _shorty_type(returns) + "".join(_shorty_type(item) for item in parameters)


def _synthetic_dex(
    classes: list[_Class],
    method_refs: tuple[_MethodRef, ...] = (),
    field_refs: tuple[_FieldRef, ...] = (),
) -> bytes:
    class_descriptors = {item.descriptor for item in classes}
    protos = {
        (method.parameters, method.returns)
        for item in classes
        for method in item.methods
    }
    protos.update(
        (method.parameters, method.returns) for method in method_refs
    )
    type_descriptors = set(class_descriptors)
    for item in classes:
        if item.superclass is not None:
            type_descriptors.add(item.superclass)
        type_descriptors.update(item.interfaces)
        type_descriptors.update(field.field_type for field in item.fields)
        type_descriptors.update(
            method.returns
            for method in item.methods
        )
        for method in item.methods:
            type_descriptors.update(method.parameters)
    for method in method_refs:
        type_descriptors.add(method.owner)
        type_descriptors.add(method.returns)
        type_descriptors.update(method.parameters)
    for field in field_refs:
        type_descriptors.add(field.owner)
        type_descriptors.add(field.field_type)
    for parameters, returns in protos:
        type_descriptors.add(returns)
        type_descriptors.update(parameters)

    strings = set(type_descriptors)
    strings.update(method.name for item in classes for method in item.methods)
    strings.update(field.name for item in classes for field in item.fields)
    strings.update(
        _shorty(parameters, returns) for parameters, returns in protos
    )
    strings.update(method.name for method in method_refs)
    strings.update(field.name for field in field_refs)

    ordered_strings = sorted(strings)
    ordered_types = sorted(type_descriptors)
    ordered_protos = sorted(protos)
    string_index = {value: index for index, value in enumerate(ordered_strings)}
    type_index = {value: index for index, value in enumerate(ordered_types)}
    proto_index = {value: index for index, value in enumerate(ordered_protos)}

    field_specs: dict[tuple[str, str, str], int] = {}
    for item in classes:
        for field in item.fields:
            field_specs[(item.descriptor, field.name, field.field_type)] = field.access
    for field in field_refs:
        field_specs.setdefault((field.owner, field.name, field.field_type), 0)
    ordered_field_specs = sorted(field_specs)
    field_index = {
        value: index for index, value in enumerate(ordered_field_specs)
    }

    method_specs: dict[tuple[str, str, tuple[str, ...], str], int] = {}
    for item in classes:
        for method in item.methods:
            method_specs[
                (item.descriptor, method.name, method.parameters, method.returns)
            ] = method.access
    for method in method_refs:
        method_specs.setdefault(
            (method.owner, method.name, method.parameters, method.returns), 0
        )
    ordered_method_specs = sorted(method_specs)
    method_index = {
        value: index for index, value in enumerate(ordered_method_specs)
    }
    ordered_classes = sorted(classes, key=lambda item: type_index[item.descriptor])

    tables_size = (
        len(ordered_strings) * 4
        + len(ordered_types) * 4
        + len(ordered_protos) * 12
        + len(ordered_field_specs) * 8
        + len(ordered_method_specs) * 8
        + len(ordered_classes) * 32
    )
    data = bytearray(112 + tables_size)
    string_ids_off = 112
    type_ids_off = string_ids_off + len(ordered_strings) * 4
    proto_ids_off = type_ids_off + len(ordered_types) * 4
    field_ids_off = proto_ids_off + len(ordered_protos) * 12
    method_ids_off = field_ids_off + len(ordered_field_specs) * 8
    class_defs_off = method_ids_off + len(ordered_method_specs) * 8
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
        struct.pack_into(
            "<I", data, offset, string_index[_shorty(parameters, returns)]
        )
        struct.pack_into("<I", data, offset + 4, type_index[returns])
        struct.pack_into("<I", data, offset + 8, add_type_list(parameters))
    for index, (owner, name, field_type) in enumerate(ordered_field_specs):
        offset = field_ids_off + index * 8
        struct.pack_into(
            "<HH", data, offset, type_index[owner], type_index[field_type]
        )
        struct.pack_into("<I", data, offset + 4, string_index[name])
    for index, (owner, name, parameters, returns) in enumerate(
        ordered_method_specs
    ):
        offset = method_ids_off + index * 8
        struct.pack_into(
            "<HH",
            data,
            offset,
            type_index[owner],
            proto_index[(parameters, returns)],
        )
        struct.pack_into("<I", data, offset + 4, string_index[name])

    for class_position, item in enumerate(ordered_classes):
        _align(data)
        class_data_offset = len(data)
        static_fields = [field for field in item.fields if field.access & 0x0008]
        instance_fields = [
            field for field in item.fields if not field.access & 0x0008
        ]
        direct_methods = [
            method
            for method in item.methods
            if method.name == "<init>"
            or method.access & (audit.ACC_PRIVATE | 0x0008)
        ]
        virtual_methods = [
            method for method in item.methods if method not in direct_methods
        ]
        data.extend(_uleb(len(static_fields)))
        data.extend(_uleb(len(instance_fields)))
        data.extend(_uleb(len(direct_methods)))
        data.extend(_uleb(len(virtual_methods)))
        for group in (static_fields, instance_fields):
            previous = 0
            for field in sorted(
                group,
                key=lambda value: field_index[
                    (item.descriptor, value.name, value.field_type)
                ],
            ):
                current = field_index[
                    (item.descriptor, field.name, field.field_type)
                ]
                data.extend(_uleb(current - previous))
                data.extend(_uleb(field.access))
                previous = current
        for group in (direct_methods, virtual_methods):
            previous = 0
            for method in sorted(
                group,
                key=lambda value: method_index[
                    (
                        item.descriptor,
                        value.name,
                        value.parameters,
                        value.returns,
                    )
                ],
            ):
                current = method_index[
                    (
                        item.descriptor,
                        method.name,
                        method.parameters,
                        method.returns,
                    )
                ]
                data.extend(_uleb(current - previous))
                data.extend(_uleb(method.access))
                data.extend(_uleb(0))
                previous = current

        offset = class_defs_off + class_position * 32
        struct.pack_into("<I", data, offset, type_index[item.descriptor])
        struct.pack_into("<I", data, offset + 4, item.access)
        superclass = (
            0xFFFFFFFF
            if item.superclass is None
            else type_index[item.superclass]
        )
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
    struct.pack_into("<II", data, 80, len(ordered_field_specs), field_ids_off)
    struct.pack_into("<II", data, 88, len(ordered_method_specs), method_ids_off)
    struct.pack_into("<II", data, 96, len(ordered_classes), class_defs_off)
    struct.pack_into("<II", data, 104, len(data) - data_off, data_off)
    return bytes(data)


def _class_file(
    name: str,
    access: int,
    super_name: str | None,
    interfaces: tuple[str, ...] = (),
    methods: tuple[tuple[str, str, int], ...] = (),
    fields: tuple[tuple[str, str, int], ...] = (),
) -> bytes:
    entries: list[tuple[object, ...]] = []

    def add_utf8(value: str) -> int:
        entries.append((1, value.encode("utf-8")))
        return len(entries)

    def add_class(value: str) -> int:
        utf8_index = add_utf8(value)
        entries.append((7, utf8_index))
        return len(entries)

    this_class = add_class(name)
    super_class = 0 if super_name is None else add_class(super_name)
    interface_indexes = tuple(add_class(value) for value in interfaces)
    field_entries = tuple(
        (access, add_utf8(field_name), add_utf8(descriptor))
        for field_name, descriptor, access in fields
    )
    method_entries = tuple(
        (access, add_utf8(method_name), add_utf8(descriptor))
        for method_name, descriptor, access in methods
    )

    output = bytearray()
    output.extend(struct.pack(">IHH", 0xCAFEBABE, 0, 52))
    output.extend(struct.pack(">H", len(entries) + 1))
    for entry in entries:
        tag = entry[0]
        output.append(tag)
        if tag == 1:
            raw = entry[1]
            assert isinstance(raw, bytes)
            output.extend(struct.pack(">H", len(raw)))
            output.extend(raw)
        elif tag == 7:
            output.extend(struct.pack(">H", entry[1]))
        else:
            raise AssertionError(f"unsupported test constant-pool tag {tag}")
    output.extend(struct.pack(">HHH", access, this_class, super_class))
    output.extend(struct.pack(">H", len(interface_indexes)))
    for index in interface_indexes:
        output.extend(struct.pack(">H", index))
    output.extend(struct.pack(">H", len(field_entries)))
    for field_access, name_index, descriptor_index in field_entries:
        output.extend(
            struct.pack(">HHHH", field_access, name_index, descriptor_index, 0)
        )
    output.extend(struct.pack(">H", len(method_entries)))
    for method_access, name_index, descriptor_index in method_entries:
        output.extend(
            struct.pack(">HHHH", method_access, name_index, descriptor_index, 0)
        )
    output.extend(struct.pack(">H", 0))
    return bytes(output)


def _write_apk(
    path: Path,
    dex: bytes,
    *,
    package_name: str = "fixture.plugin",
    version_code: int = 106000,
    version_name: str = "1.0.0",
) -> None:
    manifest = (
        '<manifest xmlns:android="http://schemas.android.com/apk/res/android" '
        f'package="{package_name}" android:versionCode="{version_code}" '
        f'android:versionName="{version_name}"/>'
    ).encode()
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("classes.dex", dex)
        archive.writestr("AndroidManifest.xml", manifest)


def _write_android_jar(path: Path) -> None:
    classes = {
        "java/lang/Object.class": _class_file(
            "java/lang/Object",
            access=0x0021,
            super_name=None,
            methods=(("<init>", "()V", 0x0001),),
        ),
        "java/lang/String.class": _class_file(
            "java/lang/String",
            access=0x0031,
            super_name="java/lang/Object",
            methods=(("length", "()I", 0x0001),),
        ),
        "java/lang/Enum.class": _class_file(
            "java/lang/Enum",
            access=0x0031,
            super_name="java/lang/Object",
            methods=(
                ("ordinal", "()I", 0x0011),
                ("hashCode", "()I", 0x0011),
                ("toString", "()Ljava/lang/String;", 0x0001),
            ),
        ),
        "java/util/List.class": _class_file(
            "java/util/List",
            access=0x0601,
            super_name="java/lang/Object",
            methods=(
                (
                    "iterator",
                    "()Ljava/util/Iterator;",
                    0x0401,
                ),
            ),
        ),
        "java/util/Iterator.class": _class_file(
            "java/util/Iterator",
            access=0x0601,
            super_name="java/lang/Object",
            methods=(
                ("hasNext", "()Z", 0x0401),
                ("next", "()Ljava/lang/Object;", 0x0401),
            ),
        ),
    }
    with zipfile.ZipFile(path, "w") as archive:
        for name, payload in classes.items():
            archive.writestr(name, payload)


def _binary_android_manifest(
    package_name: str,
    version_code: int,
    version_name: str,
) -> bytes:
    strings = (
        "manifest",
        "package",
        "http://schemas.android.com/apk/res/android",
        "versionCode",
        "versionName",
        package_name,
        version_name,
    )
    encoded_strings: list[bytes] = []
    string_offsets: list[int] = []
    payload = bytearray()
    for value in strings:
        raw = value.encode("ascii")
        string_offsets.append(len(payload))
        payload.extend((len(value), len(raw)))
        payload.extend(raw)
        payload.append(0)
    while len(payload) % 4:
        payload.append(0)
    strings_start = 28 + len(strings) * 4
    string_pool_size = strings_start + len(payload)
    string_pool = bytearray(
        struct.pack(
            "<HHIIIIII",
            0x0001,
            28,
            string_pool_size,
            len(strings),
            0,
            0x00000100,
            strings_start,
            0,
        )
    )
    for offset in string_offsets:
        string_pool.extend(struct.pack("<I", offset))
    string_pool.extend(payload)

    attributes = (
        (0xFFFFFFFF, 1, 5, 0x03, 5),
        (2, 3, 0xFFFFFFFF, 0x10, version_code),
        (2, 4, 6, 0x03, 6),
    )
    start_element_size = 36 + len(attributes) * 20
    start_element = bytearray(
        struct.pack("<HHI", 0x0102, 16, start_element_size)
    )
    start_element.extend(struct.pack("<II", 1, 0xFFFFFFFF))
    start_element.extend(
        struct.pack(
            "<IIHHHHHH",
            0xFFFFFFFF,
            0,
            20,
            20,
            len(attributes),
            0,
            0,
            0,
        )
    )
    for namespace, name, raw, data_type, value in attributes:
        start_element.extend(
            struct.pack(
                "<IIIHBBI",
                namespace,
                name,
                raw,
                8,
                0,
                data_type,
                value,
            )
        )

    total_size = 8 + len(string_pool) + len(start_element)
    return (
        struct.pack("<HHI", 0x0003, 8, total_size)
        + bytes(string_pool)
        + bytes(start_element)
    )


def _host_dex() -> bytes:
    return _synthetic_dex(
        [
            _Class(
                descriptor="Lext/PluginBase;",
                access=audit.ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("<init>", (), "V"),
                    _Method("inherited", (), "V"),
                ),
                fields=(_Field("baseField", "I"),),
            ),
            _Class(
                descriptor="Lprefix/Shadowed;",
                access=audit.ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("<init>", (), "V"),
                    _Method("call", (), "V"),
                ),
            ),
        ]
    )


def _plugin_dex() -> bytes:
    method_refs = (
        _MethodRef("Lext/Plugin;", "inherited", (), "V"),
        _MethodRef("Ljava/util/List;", "iterator", (), "Ljava/util/Iterator;"),
        _MethodRef("Lprefix/Shadowed;", "call", (), "V"),
        _MethodRef("Lprefix/Shadowed;", "wrong", (), "V"),
        _MethodRef("Lext/PrivateOwner;", "secret", (), "V"),
        _MethodRef("Lext/PluginBase;", "<init>", (), "V"),
        _MethodRef("Ljava/util/List;", "notThere", (), "V"),
        _MethodRef("Lext/Plugin;", "<init>", ("I",), "V"),
        _MethodRef("Ljava/lang/String;", "length", (), "I"),
        _MethodRef("[Ljava/lang/String;", "clone", (), "Ljava/lang/Object;"),
    )
    field_refs = (
        _FieldRef("Lext/Plugin;", "baseField", "I"),
        _FieldRef("Lprefix/Shadowed;", "value", "I"),
        _FieldRef("Lext/PrivateOwner;", "value", "I"),
        _FieldRef("Ljava/lang/String;", "missingField", "I"),
    )
    return _synthetic_dex(
        [
            _Class(
                descriptor="Lext/Plugin;",
                access=audit.ACC_PUBLIC,
                superclass="Lext/PluginBase;",
                methods=(
                    _Method("<init>", (), "V"),
                    _Method("run", (), "V"),
                    _Method(
                        "metadata",
                        ("Ldalvik/annotation/Signature;",),
                        "V",
                        audit.ACC_PRIVATE,
                    ),
                ),
            ),
            _Class(
                descriptor="Lext/PrivateOwner;",
                access=0,
                superclass="Ljava/lang/Object;",
                methods=(_Method("secret", (), "V", audit.ACC_PRIVATE),),
                fields=(_Field("value", "I", audit.ACC_PRIVATE),),
            ),
            _Class(
                descriptor="Lprefix/Shadowed;",
                access=audit.ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("<init>", (), "V"),
                    _Method("wrong", (), "V"),
                ),
                fields=(_Field("value", "I"),),
            ),
        ],
        method_refs=method_refs,
        field_refs=field_refs,
    )


def _simple_plugin_dex() -> bytes:
    return _synthetic_dex(
        [
            _Class(
                descriptor="Lfixture/Simple;",
                access=audit.ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(_Method("<init>", (), "V"),),
            )
        ]
    )


def _parent_first_plugin_dex() -> bytes:
    return _synthetic_dex(
        [
            _Class(
                descriptor="Lprefix/PluginBase;",
                access=audit.ACC_PUBLIC,
                superclass="Ljava/lang/Object;",
                methods=(
                    _Method("<init>", (), "V"),
                    _Method("inheritedFromPlugin", (), "V"),
                ),
            ),
            _Class(
                descriptor="Lprefix/PluginChild;",
                access=audit.ACC_PUBLIC,
                superclass="Lprefix/PluginBase;",
                methods=(_Method("<init>", (), "V"),),
            ),
            _Class(
                descriptor="Lprefix/Plugin$Mode;",
                access=0x0031,
                superclass="Ljava/lang/Enum;",
            ),
        ],
        method_refs=(
            _MethodRef(
                "Lprefix/PluginChild;", "inheritedFromPlugin", (), "V"
            ),
            _MethodRef("Lprefix/Plugin$Mode;", "ordinal", (), "I"),
            _MethodRef("Lprefix/Plugin$Mode;", "hashCode", (), "I"),
        ),
    )


def _write_fixture(root: Path, plugin_dex: bytes = None) -> dict[str, Path]:
    apk_dir = root / "apks"
    apk_dir.mkdir()
    host_apk = root / "host.apk"
    android_jar = root / "android.jar"
    plugin_apk = apk_dir / "fixture-plugin.apk"
    manifest = root / "index.min.json"
    host_source = root / "MihonHost.kt"
    _write_apk(host_apk, _host_dex())
    _write_android_jar(android_jar)
    _write_apk(plugin_apk, plugin_dex or _plugin_dex())
    manifest.write_text(
        json.dumps(
            [
                {
                    "pkg": "fixture.plugin",
                    "name": "Fixture Plugin",
                    "version": "1.0.0",
                    "apk": "fixture-plugin.apk",
                }
            ]
        ),
        encoding="utf-8",
    )
    host_source.write_text(
        """
class ChildFirst {
    private val parentPrefixes = arrayOf(
        "java.",
        "prefix.",
    )
}
""".strip()
        + "\n",
        encoding="utf-8",
    )
    return {
        "apk_dir": apk_dir,
        "host_apk": host_apk,
        "android_jar": android_jar,
        "plugin_apk": plugin_apk,
        "manifest": manifest,
        "host_source": host_source,
    }


class AuditMihonExtensionsTest(unittest.TestCase):
    def test_resolves_inherited_android_parent_first_and_nonpublic_definitions(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary))
            scan = audit.parse_apk_dex(paths["plugin_apk"])
            private_owner = scan.classes["Lext/PrivateOwner;"]
            self.assertEqual(0, private_owner.access_flags)
            self.assertIn("secret()V", private_owner.methods)
            self.assertIn("value:I", private_owner.fields)
            self.assertIn("Lprefix/Shadowed;->wrong()V", scan.method_refs)
            self.assertIn("Lprefix/Shadowed;->value:I", scan.field_refs)
            self.assertEqual(
                ("java.", "prefix."),
                audit.parse_parent_first_prefixes(
                    paths["host_source"].read_text(encoding="utf-8")
                ),
            )

            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        plugin = report["plugins"][0]
        missing_methods = {
            item["descriptor"] for item in plugin["missing"]["methods"]
        }
        missing_fields = {
            item["descriptor"] for item in plugin["missing"]["fields"]
        }
        self.assertEqual("indeterminate", plugin["status"])
        self.assertTrue(plugin["blocked"])
        self.assertFalse(plugin["staticResolutionComplete"])
        self.assertIn(
            "parent-first-shadowed-class", plugin["blockedReasons"]
        )
        self.assertFalse(plugin["runtimeVerified"])
        self.assertIn("Ljava/util/List;->notThere()V", missing_methods)
        self.assertIn("Lext/Plugin;-><init>(I)V", missing_methods)
        self.assertNotIn("Ljava/util/List;->iterator()Ljava/util/Iterator;", missing_methods)
        self.assertNotIn("Lext/Plugin;->inherited()V", missing_methods)
        self.assertNotIn("Lprefix/Shadowed;->call()V", missing_methods)
        self.assertNotIn(
            "[Ljava/lang/String;->clone()Ljava/lang/Object;", missing_methods
        )
        self.assertIn("Ljava/lang/String;->missingField:I", missing_fields)
        self.assertNotIn("Lext/Plugin;->baseField:I", missing_fields)
        self.assertEqual(3, plugin["coverage"]["combined"]["missing"])
        self.assertEqual(
            ["Ldalvik/annotation/Signature;"],
            plugin["ignoredPlatformMetadataClasses"],
        )
        self.assertNotIn(
            "Ldalvik/annotation/Signature;",
            {item["descriptor"] for item in plugin["missing"]["classes"]},
        )
        codes = {item["code"] for item in plugin["uncertainties"]}
        self.assertIn("parent-first-shadowed-plugin-class", codes)
        self.assertEqual("not-run", report["runtimeStatus"])
        self.assertFalse(report["runtimeVerified"])

    def test_static_resolution_is_never_reported_as_runtime_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        plugin = report["plugins"][0]
        self.assertEqual("static-resolved", plugin["status"])
        self.assertEqual("not-run", report["runtimeStatus"])
        self.assertFalse(report["runtimeVerified"])
        self.assertNotIn("runtime success", plugin["status"].lower())
        self.assertIn("not runtime success", report["claim"])
        self.assertEqual(1.0, report["summary"]["pluginAuditRatio"])

    def test_parent_first_plugin_definitions_are_used_after_parent_miss(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(
                Path(temporary), _parent_first_plugin_dex()
            )
            scan = audit.parse_apk_dex(paths["plugin_apk"])
            universe = audit.SymbolUniverse(
                scan.classes,
                {},
                audit.parse_android_jar(paths["android_jar"]),
                ("java.", "prefix."),
            )
            inherited = universe.resolve_method(
                "Lprefix/PluginChild;->inheritedFromPlugin()V"
            )
            enum_ordinal = universe.resolve_method(
                "Lprefix/Plugin$Mode;->ordinal()I"
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual("resolved", inherited.status)
        self.assertEqual("plugin", inherited.source)
        self.assertEqual("Lprefix/PluginBase;", inherited.declaring_class)
        self.assertEqual("resolved", enum_ordinal.status)
        self.assertEqual("android", enum_ordinal.source)
        self.assertEqual("Ljava/lang/Enum;", enum_ordinal.declaring_class)
        plugin = report["plugins"][0]
        self.assertEqual("static-resolved", plugin["status"])
        self.assertEqual(
            {"classes": [], "methods": [], "fields": []},
            {
                key: plugin["missing"][key]
                for key in ("classes", "methods", "fields")
            },
        )
        codes = {item["code"] for item in plugin["uncertainties"]}
        self.assertNotIn("parent-first-shadowed-plugin-class", codes)
        self.assertNotIn("parent-first-unavailable-plugin-class", codes)

    def test_binary_android_manifest_identity_is_parsed(self) -> None:
        identity = audit._parse_binary_android_manifest(
            _binary_android_manifest("fixture.plugin", 106000, "1.0.0")
        )

        self.assertEqual("fixture.plugin", identity.package_name)
        self.assertEqual(106000, identity.version_code)
        self.assertEqual("1.0.0", identity.version_name)

    def test_manifest_sha256_rejects_same_name_replaced_apk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            expected_sha256 = audit._sha256(paths["plugin_apk"])
            _write_apk(paths["plugin_apk"], _parent_first_plugin_dex())
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "name": "Fixture Plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "status": "already_present",
                                "local_path": "fixture-plugin.apk",
                                "sha256": expected_sha256,
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            "manifest-apk-integrity-mismatch",
            report["notAudited"][0]["reason"],
        )
        self.assertEqual(
            expected_sha256,
            report["notAudited"][0]["metadata"]["download"]["sha256"],
        )
        self.assertEqual(
            expected_sha256,
            report["notAudited"][0]["expectedIntegrity"]["sha256"][0][
                "value"
            ],
        )

    def test_manifest_expected_size_and_asset_sha_are_enforced(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            actual_sha256 = audit._sha256(paths["plugin_apk"])
            actual_bytes = paths["plugin_apk"].stat().st_size
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": "fixture-plugin.apk",
                                "sha256": actual_sha256,
                                "asset_sha256": actual_sha256,
                                "size": actual_bytes + 1,
                                "validation": {"ok": True},
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        item = report["notAudited"][0]
        self.assertEqual("manifest-apk-integrity-mismatch", item["reason"])
        self.assertEqual(
            actual_sha256, item["metadata"]["download"]["asset_sha256"]
        )
        self.assertEqual(
            actual_bytes + 1, item["metadata"]["download"]["size"]
        )
        self.assertEqual(
            actual_bytes + 1, item["expectedIntegrity"]["bytes"][0]["value"]
        )

    def test_manifest_failed_validation_is_not_audited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            digest = audit._sha256(paths["plugin_apk"])
            validation = {"ok": False, "reason": "signature mismatch"}
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": "fixture-plugin.apk",
                                "sha256": digest,
                                "validation": validation,
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            "manifest-validation-failed",
            report["notAudited"][0]["reason"],
        )
        self.assertEqual(
            validation,
            report["notAudited"][0]["metadata"]["download"]["validation"],
        )
        self.assertEqual(
            validation,
            report["notAudited"][0]["expectedIntegrity"]["validation"][0][
                "value"
            ],
        )

    def test_same_name_apk_collision_does_not_fall_back_to_other_bytes(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            paths["plugin_apk"].unlink()
            first = paths["apk_dir"] / "first/fixture-plugin.apk"
            second = paths["apk_dir"] / "second/fixture-plugin.apk"
            first.parent.mkdir()
            second.parent.mkdir()
            _write_apk(first, _simple_plugin_dex())
            _write_apk(second, _parent_first_plugin_dex())
            expected_sha256 = audit._sha256(second)
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": "first/fixture-plugin.apk",
                                "sha256": expected_sha256,
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            "manifest-apk-integrity-mismatch",
            report["notAudited"][0]["reason"],
        )
        self.assertNotEqual(
            str(second.resolve()),
            report["notAudited"][0].get("apkPath"),
        )

    def test_manifest_identity_rejects_wrong_package_and_version(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "wrong.package",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "apk": "fixture-plugin.apk",
                        },
                        {
                            "pkg": "fixture.plugin",
                            "version": "9.9.9",
                            "versionCode": 999999,
                            "apk": "fixture-plugin.apk",
                        },
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            [
                "manifest-apk-identity-mismatch",
                "manifest-apk-identity-mismatch",
            ],
            [
                item["reason"]
                for item in report["notAudited"][:2]
            ],
        )

    def test_missing_local_path_without_strong_sha_is_not_guessed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": (
                                    "missing/fixture-plugin.apk"
                                )
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            "manifest-apk-missing",
            report["notAudited"][0]["reason"],
        )

    def test_missing_local_path_uses_unique_strong_sha_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            matching = paths["apk_dir"] / "matching.apk"
            _write_apk(matching, _parent_first_plugin_dex())
            digest = audit._sha256(matching)
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "status": "already_present",
                                "local_path": "missing/fixture-plugin.apk",
                                "sha256": digest,
                                "asset_sha256": digest,
                            },
                        }
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual(1, report["summary"]["pluginsAudited"])
        plugin = report["plugins"][0]
        self.assertEqual(str(matching.resolve()), plugin["apk"]["path"])
        self.assertIn(
            "strong-sha256-fallback", plugin["apk"]["bindingEvidence"]
        )
        self.assertEqual(
            digest,
            plugin["apk"]["expectedIntegrity"]["assetSha256"][0]["value"],
        )

    def test_same_sha_can_be_referenced_by_multiple_snapshots(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            digest = audit._sha256(paths["plugin_apk"])
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "name": "Snapshot A",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": "fixture-plugin.apk",
                                "sha256": digest,
                            },
                        },
                        {
                            "pkg": "fixture.plugin",
                            "name": "Snapshot B",
                            "version": "1.0.0",
                            "versionCode": 106000,
                            "download": {
                                "local_path": "fixture-plugin.apk",
                                "sha256": digest,
                            },
                        },
                    ]
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual(2, report["summary"]["pluginsAudited"])
        self.assertEqual(0, report["summary"]["notAudited"])
        self.assertEqual(
            {str(paths["plugin_apk"].resolve())},
            {plugin["apk"]["path"] for plugin in report["plugins"]},
        )

    def test_parent_first_shadowing_blocks_cli_success(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _plugin_dex())
            output = paths["host_apk"].parent / "audit.json"
            exit_code = audit.main(
                [
                    "--manifest",
                    str(paths["manifest"]),
                    "--apk-dir",
                    str(paths["apk_dir"]),
                    "--host-apk",
                    str(paths["host_apk"]),
                    "--android-jar",
                    str(paths["android_jar"]),
                    "--mihon-host-source",
                    str(paths["host_source"]),
                    "--output",
                    str(output),
                ]
            )
            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(1, exit_code)
        self.assertEqual("indeterminate", payload["plugins"][0]["status"])
        self.assertEqual(1, payload["summary"]["pluginsIndeterminate"])

    def test_missing_and_unreferenced_apks_are_reported_as_not_audited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root)
            paths["manifest"].write_text(
                json.dumps(
                    [
                        {
                            "pkg": "fixture.plugin",
                            "name": "Fixture Plugin",
                            "apk": "fixture-plugin.apk",
                        },
                        {
                            "pkg": "fixture.missing",
                            "name": "Missing Plugin",
                            "apk": "missing-plugin.apk",
                        },
                    ]
                ),
                encoding="utf-8",
            )
            (paths["apk_dir"] / "extra.apk").write_bytes(
                paths["plugin_apk"].read_bytes()
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        reasons = {item["reason"] for item in report["notAudited"]}
        self.assertIn("manifest-apk-missing", reasons)
        self.assertIn("apk-not-referenced-by-manifest", reasons)
        self.assertEqual(2, report["summary"]["expectedPluginEntries"])
        self.assertEqual(1, report["summary"]["pluginsAudited"])
        self.assertEqual(2, report["summary"]["notAudited"])

    def test_directory_only_mode_audits_each_apk(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            report = audit.build_report(
                manifest_path=None,
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual(1, report["summary"]["pluginsAudited"])
        self.assertEqual(0, report["summary"]["notAudited"])
        self.assertEqual("static-resolved", report["plugins"][0]["status"])

    def test_compat_audit_jsonl_and_nested_download_path_are_consumed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root, _simple_plugin_dex())
            compat_root = root / "compat-audit"
            nested_apk = (
                compat_root
                / "apks/keiyoushi/extensions/tag/fixture-plugin.apk"
            )
            nested_apk.parent.mkdir(parents=True)
            shutil.copyfile(paths["plugin_apk"], nested_apk)
            manifest = compat_root / "apk-manifest.jsonl"
            manifest.write_text(
                json.dumps(
                    {
                        "manifest_version": 1,
                        "package_name": "fixture.plugin",
                        "name": "Fixture Plugin",
                        "version_name": "1.0.0",
                        "extension_lib": "1.6",
                        "download": {
                            "status": "already_present",
                            "local_path": (
                                "apks/keiyoushi/extensions/tag/"
                                "fixture-plugin.apk"
                            ),
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=manifest,
                apk_dir=compat_root / "apks",
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        plugin = report["plugins"][0]
        self.assertEqual("fixture.plugin", plugin["metadata"]["pkg"])
        self.assertEqual("1.6", plugin["metadata"]["extensionLib"])
        self.assertEqual(
            "already_present", plugin["metadata"]["downloadStatus"]
        )
        self.assertEqual(str(nested_apk.resolve()), plugin["apk"]["path"])
        self.assertEqual(0, report["summary"]["notAudited"])

    def test_snapshot_extension_list_and_resource_url_are_consumed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root, _simple_plugin_dex())
            asset = paths["apk_dir"] / "tachiyomi-fixture-v1.apk"
            paths["plugin_apk"].replace(asset)
            paths["manifest"].write_text(
                json.dumps(
                    {
                        "extensionList": {
                            "extensions": [
                                {
                                    "name": "Fixture Plugin",
                                    "packageName": "fixture.plugin",
                                    "resources": {
                                        "apkUrl": (
                                            "https://example.invalid/"
                                            "tachiyomi-fixture-v1.apk"
                                        ),
                                    },
                                    "extensionLib": "1.6",
                                    "versionCode": "106000",
                                    "versionName": "1.0.0",
                                    "sources": [],
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual(1, report["summary"]["pluginsAudited"])
        self.assertEqual(
            "fixture.plugin", report["plugins"][0]["metadata"]["pkg"]
        )
        self.assertIn(
            "apk-url-basename",
            report["plugins"][0]["apk"]["bindingEvidence"],
        )
        self.assertNotIn(
            "sha256",
            report["plugins"][0]["apk"]["expectedIntegrity"],
        )

    def test_apk_url_basename_requires_package_and_version_identity(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root, _simple_plugin_dex())
            asset = paths["apk_dir"] / "tachiyomi-fixture-v1.apk"
            paths["plugin_apk"].replace(asset)
            paths["manifest"].write_text(
                json.dumps(
                    {
                        "extensionList": {
                            "extensions": [
                                {
                                    "name": "Wrong Package",
                                    "packageName": "wrong.package",
                                    "resources": {
                                        "apkUrl": (
                                            "https://example.invalid/"
                                            "tachiyomi-fixture-v1.apk"
                                        )
                                    },
                                    "versionCode": "106000",
                                    "versionName": "1.0.0",
                                    "sources": [],
                                },
                                {
                                    "name": "Wrong Version",
                                    "packageName": "fixture.plugin",
                                    "resources": {
                                        "apkUrl": (
                                            "https://example.invalid/"
                                            "tachiyomi-fixture-v1.apk"
                                        )
                                    },
                                    "versionCode": "999999",
                                    "versionName": "9.9.9",
                                    "sources": [],
                                },
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual([], report["plugins"])
        self.assertEqual(
            [
                "manifest-apk-identity-mismatch",
                "manifest-apk-identity-mismatch",
            ],
            [
                item["reason"]
                for item in report["notAudited"][:2]
            ],
        )

    def test_apk_url_release_path_disambiguates_duplicate_basenames(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root, _simple_plugin_dex())
            paths["plugin_apk"].unlink()
            old = (
                paths["apk_dir"]
                / "keiyoushi/extensions/tag-old/tachiyomi-fixture-v1.apk"
            )
            current = (
                paths["apk_dir"]
                / "keiyoushi/extensions/tag-current/tachiyomi-fixture-v1.apk"
            )
            old.parent.mkdir(parents=True)
            current.parent.mkdir(parents=True)
            _write_apk(old, _simple_plugin_dex())
            _write_apk(current, _parent_first_plugin_dex())
            paths["manifest"].write_text(
                json.dumps(
                    {
                        "extensionList": {
                            "extensions": [
                                {
                                    "name": "Fixture Plugin",
                                    "packageName": "fixture.plugin",
                                    "resources": {
                                        "apkUrl": (
                                            "https://github.com/keiyoushi/"
                                            "extensions/releases/download/"
                                            "tag-current/"
                                            "tachiyomi-fixture-v1.apk"
                                        )
                                    },
                                    "versionCode": "106000",
                                    "versionName": "1.0.0",
                                    "sources": [],
                                }
                            ]
                        }
                    }
                ),
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        plugin = report["plugins"][0]
        self.assertEqual(str(current.resolve()), plugin["apk"]["path"])
        self.assertIn(
            "apk-url-release-path", plugin["apk"]["bindingEvidence"]
        )

    def test_pending_download_is_reported_not_audited(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            paths = _write_fixture(root, _simple_plugin_dex())
            paths["manifest"].write_text(
                json.dumps(
                    {
                        "package_name": "fixture.plugin",
                        "name": "Fixture Plugin",
                        "download": {
                            "status": "pending",
                            "local_path": None,
                        },
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            report = audit.build_report(
                manifest_path=paths["manifest"],
                apk_dir=paths["apk_dir"],
                host_apk=paths["host_apk"],
                android_jar=paths["android_jar"],
                mihon_host_source=paths["host_source"],
            )

        self.assertEqual(0, report["summary"]["pluginsAudited"])
        self.assertEqual("download-pending", report["notAudited"][0]["reason"])

    def test_invalid_parent_prefix_source_is_an_input_error(self) -> None:
        with self.assertRaises(audit.AuditInputError):
            audit.parse_parent_first_prefixes("class MissingPrefixes {}")

    def test_keiyoushi_status_stub_is_flagged_as_incomplete_manifest(self) -> None:
        warnings = audit.manifest_warnings(
            [
                {
                    "pkg": "eu.kanade.tachiyomi.extension.all.keiyoushi",
                    "name": "Outdated App",
                },
                {
                    "pkg": "eu.kanade.tachiyomi.extension.all.mihon",
                    "name": "Update to Mihon 0.20.1+",
                },
            ]
        )
        self.assertEqual(
            "manifest-may-be-keiyoushi-status-stub", warnings[0]["code"]
        )

    def test_cli_writes_json_without_claiming_runtime_validation(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            paths = _write_fixture(Path(temporary), _simple_plugin_dex())
            output = paths["host_apk"].parent / "audit.json"
            exit_code = audit.main(
                [
                    "--manifest",
                    str(paths["manifest"]),
                    "--apk-dir",
                    str(paths["apk_dir"]),
                    "--host-apk",
                    str(paths["host_apk"]),
                    "--android-jar",
                    str(paths["android_jar"]),
                    "--mihon-host-source",
                    str(paths["host_source"]),
                    "--output",
                    str(output),
                ]
            )
            payload = json.loads(output.read_text(encoding="utf-8"))

        self.assertEqual(0, exit_code)
        self.assertEqual("not-run", payload["runtimeStatus"])
        self.assertFalse(payload["runtimeVerified"])


if __name__ == "__main__":
    unittest.main()
