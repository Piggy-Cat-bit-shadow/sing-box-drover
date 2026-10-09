#!/usr/bin/env python3
"""Generates app.res, the single Windows resource file for the JieJieBox shell.

Why this script exists
----------------------
The tray icon resources are addressed by *name* at runtime
(`TIcon.LoadFromResourceName(HInstance, 'TRAY_ICON')`). The classic way to get
them there is an .rc file compiled by brcc32, but brcc32 only exists inside a
RAD Studio installation. Producing the binary .res here instead keeps the build
free of any extra tool: `{$R 'app.res'}` in the .dpr is all the compiler needs on
any machine.

What it emits
-------------
* MAINICON      - group icon built from icon.ico            (application icon)
* TRAY_ICON     - group icon built from icon.ico            (core running)
* TRAY_ICON_DISABLED - group icon built from icon_disabled.ico
* TRAY_ICON_TUN - group icon built from icon_tun.ico
* VERSION       - VERSIONINFO #1, language 1033
* MANIFEST      - RT_MANIFEST #1, PerMonitorV2 + common controls v6

Usage (from the repository root):
    python3 tools/make_app_res.py
"""

import os
import struct
import sys

RT_ICON = 3
RT_GROUP_ICON = 14
RT_VERSION = 16
RT_MANIFEST = 24

MAINICON = "MAINICON"
TRAY_ICON = "TRAY_ICON"
TRAY_ICON_DISABLED = "TRAY_ICON_DISABLED"
TRAY_ICON_TUN = "TRAY_ICON_TUN"

# First ordinal handed out to the individual RT_ICON images.
FIRST_ICON_ID = 1

VERSION = {
    "FileDescription": "JieJieBox for Windows",
    "FileVersion": "0.1.5.0",
    "InternalName": "JieJieBox",
    "LegalCopyright": "",
    "OriginalFilename": "JieJieBox.exe",
    "ProductName": "JieJieBox",
    "ProductVersion": "0.1.5.0",
    "Comments": "Lightweight Windows tray shell for the custom sing-box core",
}

MANIFEST = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
  <asmv3:application>
    <asmv3:windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </asmv3:windowsSettings>
  </asmv3:application>
  <dependency>
    <dependentAssembly>
      <assemblyIdentity
        type="win32"
        name="Microsoft.Windows.Common-Controls"
        version="6.0.0.0"
        publicKeyToken="6595b64144ccf1df"
        language="*"
        processorArchitecture="*"/>
    </dependentAssembly>
  </dependency>
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security>
      <requestedPrivileges>
        <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
"""


def pad4(data):
    return data + b"\x00" * ((4 - len(data) % 4) % 4)


def read_ico(path):
    """Returns (entries, images) where entries are the ICONDIRENTRY tuples."""
    with open(path, "rb") as handle:
        raw = handle.read()

    reserved, ico_type, count = struct.unpack_from("<HHH", raw, 0)
    if reserved != 0 or ico_type != 1:
        raise ValueError("%s is not an icon file" % path)

    entries = []
    images = []
    for index in range(count):
        (width, height, colors, rsvd, planes, bpp, size, offset) = struct.unpack_from(
            "<BBBBHHII", raw, 6 + index * 16
        )
        entries.append((width, height, colors, rsvd, planes, bpp, size))
        images.append(raw[offset : offset + size])

    return entries, images


def build_group_icon(entries, image_ids):
    """GRPICONDIR + GRPICONDIRENTRY list (14 bytes per entry)."""
    out = struct.pack("<HHH", 0, 1, len(entries))
    for entry, image_id in zip(entries, image_ids):
        width, height, colors, rsvd, planes, bpp, size = entry
        out += struct.pack(
            "<BBBBHHIH", width, height, colors, rsvd, planes, bpp, size, image_id
        )
    return out


def build_version_info(values):
    """A minimal but well-formed VS_VERSIONINFO block."""

    def utf16z(text):
        return text.encode("utf-16-le") + b"\x00\x00"

    def block(key, value_bytes, value_length, value_type, children=b""):
        header = struct.pack("<HHH", 0, value_length, value_type) + utf16z(key)
        header = pad4(header)
        body = value_bytes
        body = pad4(body)
        children = pad4(children)
        total = len(header) + len(body) + len(children)
        return struct.pack("<H", total) + header[2:] + body + children

    def string_block(key, text):
        value = utf16z(text)
        return block(key, value, len(value) // 2, 1)

    # Fixed file info: signature, struct version, file version, product version,
    # flags mask, flags, file OS, file type, subtype, file date, and two spares.
    fixed = struct.pack(
        "<IIIIIIIIIIIII",
        0xFEEF04BD,  # signature
        0x00010000,  # struct version
        version_dword(values["FileVersion"]),  # file version MS
        0x00000000,  # file version LS
        version_dword(values["ProductVersion"]),  # product version MS
        0x00000000,  # product version LS
        0x0000003F,  # file flags mask
        0x00000000,  # file flags
        0x00040004,  # file OS: VOS_NT_WINDOWS32
        0x00000001,  # file type: VFT_APP
        0x00000000,  # file subtype
        0x00000000,  # file date MS
        0x00000000,  # file date LS
    )

    string_keys = [
        "Comments",
        "FileDescription",
        "FileVersion",
        "InternalName",
        "LegalCopyright",
        "OriginalFilename",
        "ProductName",
        "ProductVersion",
    ]

    children = b""
    for key in string_keys:
        children += string_block(key, values.get(key, ""))

    string_table = block("StringFileInfo", b"", 0, 1,
                         block("040904B0", b"", 0, 1, children))

    translation = struct.pack("<HH", 0x0409, 0x04B0)
    var_block = block("VarFileInfo", b"", 0, 1,
                      block("Translation", translation, len(translation) // 2, 0))

    return block("VS_VERSION_INFO", fixed, len(fixed) // 2, 0, string_table + var_block)


def version_dword(text):
    parts = [int(p) for p in text.split(".")]
    while len(parts) < 4:
        parts.append(0)
    return (parts[0] << 16) | (parts[1] & 0xFFFF) | ((parts[2] & 0xFF) << 8) | (parts[3] & 0xFF)


class ResourceFile:
    def __init__(self):
        self.chunks = []

    def add(self, type_id, name, data, language=1033):
        header = struct.pack("<HH", 0xFFFF, type_id)
        if isinstance(name, int):
            header += struct.pack("<HH", 0xFFFF, name)
        else:
            header += name.encode("utf-16-le") + b"\x00\x00"
        header += struct.pack("<HH", language, 0)
        header = pad4(header)

        # ResDirEntry layout: DataSize, HeaderSize, then the header body.
        chunk = struct.pack("<II", len(data), 8 + (len(header) - 4)) + header[4:] + pad4(data)
        self.chunks.append(chunk)

    def save(self, path):
        with open(path, "wb") as handle:
            for chunk in self.chunks:
                handle.write(chunk)


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    res_path = os.path.join(root, "app.res")

    icon_files = [
        (TRAY_ICON, os.path.join(root, "icon.ico")),
        (TRAY_ICON_DISABLED, os.path.join(root, "icon_disabled.ico")),
        (TRAY_ICON_TUN, os.path.join(root, "icon_tun.ico")),
        (MAINICON, os.path.join(root, "icon.ico")),
    ]

    res = ResourceFile()
    next_id = FIRST_ICON_ID

    for group_name, ico_path in icon_files:
        if not os.path.exists(ico_path):
            print("missing icon: %s" % ico_path, file=sys.stderr)
            return 1

        entries, images = read_ico(ico_path)
        image_ids = []
        for image in images:
            image_ids.append(next_id)
            res.add(RT_ICON, next_id, image)
            next_id += 1

        res.add(RT_GROUP_ICON, group_name, build_group_icon(entries, image_ids))
        print("%-20s <- %s (%d images)" % (group_name, os.path.basename(ico_path), len(images)))

    res.add(RT_VERSION, 1, build_version_info(VERSION))
    res.add(RT_MANIFEST, 1, MANIFEST.encode("utf-8"))

    res.save(res_path)
    print("wrote %s (%d bytes)" % (res_path, os.path.getsize(res_path)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
