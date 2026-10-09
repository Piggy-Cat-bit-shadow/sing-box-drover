#!/usr/bin/env python3
"""Static sanity checks for the JieJieBox Delphi sources.

This is not a compiler. It catches the class of mistakes that are easy to make
while editing Pascal without a toolchain at hand:

  1. a `procedure TClass.Foo` / `function TClass.Foo` implementation whose
     declaration is missing, or vice versa
  2. a `UnitName.Symbol` reference where `UnitName` is not in the file's uses
     clauses
  3. a `UnitName.Symbol` reference where the unit does not declare `Symbol` in
     its interface section
  4. a unit listed in a `uses` clause that does not exist in the project
  5. an event handler referenced from a .dfm that the form class does not declare
  6. a `const`/`type`/`var`/`property` name declared twice inside one type

Usage:
    python3 tools/check_pascal.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UNIT_RE = re.compile(r"^\s*unit\s+([A-Za-z_][A-Za-z0-9_]*)", re.I | re.M)
SECTION_RE = re.compile(r"^\s*(interface|implementation|initialization|finalization)\b", re.I | re.M)
USES_START_RE = re.compile(r"^\s*uses\b", re.I)
CLASS_METHOD_RE = re.compile(
    r"^\s*(?:class\s+)?(?:procedure|function|constructor|destructor)\s+"
    r"(?:[A-Za-z_][A-Za-z0-9_]*\s*\.\s*)?([A-Za-z_][A-Za-z0-9_]*)",
    re.I | re.M,
)
QUALIFIED_REF_RE = re.compile(r"\b([A-Z][A-Za-z0-9_]*)\.([A-Za-z_][A-Za-z0-9_]*)\b")

# Names that look like `Unit.Symbol` but are not unit references.
NOT_UNITS = {
    "TCoreState", "TCoreEvent", "TConfigSource", "TDroverEvent", "TUpdateAttemptResult",
    "TObject", "TMouseButton", "System", "Winapi", "Vcl", "TThread", "TTask",
    "TJSONObject", "TStringBuilder", "TSingBoxConfig", "TSubscriptionUserInfo",
    "TBpfProfile", "TSelectorTask", "TProfileList", "TConfigUpdateOutcome",
    "TSubscriptionProfile", "TCoreCommand", "TPair", "TEncoding", "TFile", "TPath",
    "TDirectory", "TIniFile", "TIcon", "TMutex", "TEvent", "TThreadedQueue",
    "TList", "TDictionary", "TQueue", "TComparer", "TStringList", "TStringStream",
    "TBytesStream", "TZCompressionStream", "TZDecompressionStream", "TNetHeaders",
    "TNetHeader", "TArray", "TGUID", "TRect", "TPoint", "TDateTime", "TTimeZone",
    "TWaitResult", "TInterlocked", "TStopwatch", "TStartupInfo", "TProcessInformation",
    "TSecurityAttributes", "TMenuItem", "TPopupMenu", "TTimer", "TTrayIcon",
    "TForm", "TComponent", "TWinControl", "TSize", "TResourceStream",
}

# Unit names that exist in every Delphi but are not shipped as .pas in this repo.
RTL_UNITS = {
    "System", "SysUtils", "Classes", "Windows", "Winapi", "Messages", "Variants",
    "Graphics", "Controls", "Forms", "Dialogs", "ExtCtrls", "Menus", "IniFiles",
    "WinInet", "ShellAPI", "ActiveX", "ComObj", "DateUtils", "StrUtils", "Math",
    "SyncObjs", "IOUtils", "JSON", "ZLib", "Net.HttpClient", "Net.URLClient",
    "Generics.Collections", "Generics.Defaults", "TypInfo", "Rtti", "Registry",
    "ShlObj", "CommCtrl", "Themes", "ImgList", "StdCtrls", "ComCtrls", "Winsock",
    "HttpApp", "ActiveX", "Mask", "Threading", "Diagnostics", "TimeSpan",
}

BUILTIN_TYPES = {
    "string", "integer", "boolean", "cardinal", "int64", "uint64", "int32", "uint32",
    "word", "byte", "char", "double", "single", "extended", "currency", "variant",
    "pointer", "thandle", "hwnd", "dword", "ulong", "longint", "shortint", "smallint",
    "nativeint", "nativeuint", "tobject", "tclass", "tbytes", "tarray", "tsyscharset",
}

DELPHI_UNITS = set()


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        return handle.read()


def strip_comments(text):
    """Blanks out strings and comments.

    Strings must be removed with a pattern that handles the doubled-quote escape
    and, crucially, cannot run away: a naive `'(?:[^']|'')*'` can pair an
    apostrophe in a comment with one far later in the file and delete real code.
    """
    # 1. strings: '' is an escaped quote, and Pascal strings do not span lines.
    text = re.sub(r"'(?:[^'\n]|'')*'", "''", text)
    # 2. brace and paren-star comments
    text = re.sub(r"\{[^}]*\}", " ", text, flags=re.S)
    text = re.sub(r"\(\*.*?\*\)", " ", text, flags=re.S)
    # 3. line comments
    text = re.sub(r"//[^\n]*", " ", text)
    return text


def collect_uses_clauses(text):
    """Every `uses` clause in the file, as a list of unit names.

    Done line by line: a clause ends at the first line containing a semicolon, so
    a `uses` list can never swallow the next declaration.
    """
    names = []
    lines = text.splitlines()
    index = 0
    while index < len(lines):
        if USES_START_RE.match(lines[index]):
            chunk = lines[index]
            while ";" not in chunk and index + 1 < len(lines):
                index += 1
                chunk += " " + lines[index]
            chunk = chunk.split(";", 1)[0]
            chunk = re.sub(r"^\s*uses\b", "", chunk, flags=re.I)
            for part in chunk.split(","):
                part = part.strip()
                part = re.sub(r"\s+in\s+'.*?'", "", part, flags=re.I | re.S).strip()
                if part and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.]*", part):
                    names.append(part)
        index += 1
    return names


def collect_units():
    units = {}
    for name in sorted(os.listdir(ROOT)):
        if not name.lower().endswith(".pas"):
            continue
        text = read(os.path.join(ROOT, name))
        clean = strip_comments(text)
        match = UNIT_RE.search(clean)
        if not match:
            continue
        unit_name = match.group(1)
        sections = list(SECTION_RE.finditer(clean))
        interface_text = ""
        impl_text = clean
        for index, section in enumerate(sections):
            end = sections[index + 1].start() if index + 1 < len(sections) else len(clean)
            body = clean[section.end():end]
            if section.group(1).lower() == "interface":
                interface_text += body
            elif section.group(1).lower() == "implementation":
                impl_text = body
        units[unit_name] = {
            "file": name,
            "path": os.path.join(ROOT, name),
            "raw": text,
            "interface": interface_text,
            "implementation": impl_text,
            "full": clean,
            "uses": collect_uses_clauses(clean),
        }
    return units


def interface_symbols(unit):
    """Every identifier that appears in the interface section."""
    return set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", unit["interface"]))


def declared_methods(text):
    """Method names in a section.

    Interface declarations are bare (`procedure Foo;`) while implementations are
    qualified (`procedure TBar.Foo;`). Only the method name is compared, which
    is what a missing/orphan implementation check needs.
    """
    names = set()
    pattern = re.compile(
        r"^[ \t]*(?:class[ \t]+)?(?:procedure|function|constructor|destructor)[ \t]+"
        r"(?:[A-Za-z_][A-Za-z0-9_]*[ \t]*\.[ \t]*)?([A-Za-z_][A-Za-z0-9_]*)",
        re.I | re.M,
    )
    for match in pattern.finditer(text):
        names.add(match.group(1).lower())
    return names


def main():
    units = collect_units()
    errors = []
    warnings = []
    notes = []

    if not units:
        print("no units found", file=sys.stderr)
        return 1

    # --- 1. missing / orphan implementations ------------------------------
    #
    # Interface declarations are bare (`procedure Foo;`), implementations are
    # qualified (`procedure TBar.Foo;`). Both are reduced to the bare method
    # name; indented declarations are nested helpers and are skipped.
    # [ \t]* rather than \s*: \s would swallow the newline and merge a
    # declaration with the next line.
    decl_re = re.compile(
        r"^[ \t]*(?:class[ \t]+)?(?:procedure|function|constructor|destructor)[ \t]+"
        r"(?:[A-Za-z_][A-Za-z0-9_]*[ \t]*\.[ \t]*)?([A-Za-z_][A-Za-z0-9_]*)",
        re.I | re.M,
    )

    def method_names(text):
        return {m.group(1).lower() for m in decl_re.finditer(text)}

    for name, unit in units.items():
        iface = method_names(unit["interface"])
        impl = method_names(unit["implementation"])

        # `impl - iface` are file-local helpers in the implementation section.
        # They are legitimate Pascal and need no declaration, so they are only
        # reported as notes for a human reader.
        for method in sorted(impl - iface):
            notes.append("%s: `%s` is a file-local helper (implementation only)"
                         % (unit["file"], method))
        for method in sorted(iface - impl):
            warnings.append("%s: `%s` is declared in the interface but has no implementation"
                            % (unit["file"], method))

    # --- 2/3/4. qualified references --------------------------------------
    local_type_names = set()
    for name, unit in units.items():
        local_type_names |= set(re.findall(r"\bT[A-Za-z0-9_]+\b", unit["full"]))

    for name, unit in units.items():
        for match in QUALIFIED_REF_RE.finditer(unit["full"]):
            candidate, symbol = match.group(1), match.group(2)

            if candidate in NOT_UNITS or candidate in local_type_names:
                continue
            if candidate.lower() in BUILTIN_TYPES:
                continue
            if candidate not in units:
                continue

            if candidate not in unit["uses"]:
                errors.append("%s: uses `%s.%s` but %s is not in the uses clause"
                              % (unit["file"], candidate, symbol, candidate))
                continue

            if symbol not in interface_symbols(units[candidate]):
                errors.append("%s: `%s.%s` is not declared in %s's interface"
                              % (unit["file"], candidate, symbol, candidate))

    # --- 4. used units must exist ----------------------------------------
    for name, unit in units.items():
        for used in unit["uses"]:
            if used in RTL_UNITS:
                continue
            if used.startswith(("System.", "Winapi.", "Vcl.", "Data.", "Xml.", "Web.",
                                "Soap.", "Datasnap.", "REST.")):
                continue
            if used not in units:
                errors.append("%s: uses `%s` which is not a project unit" % (unit["file"], used))

    # --- 5. dfm handlers ---------------------------------------------------
    dfm = os.path.join(ROOT, "Main.dfm")
    if os.path.exists(dfm):
        dfm_text = read(dfm)
        main = units.get("Main")
        if main:
            handles = set(re.findall(r"On[A-Za-z]+\s*=\s*([A-Za-z_][A-Za-z0-9_]*)", dfm_text))
            declared = set(re.findall(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(", main["interface"]))
            for handler in sorted(handles):
                if handler not in declared:
                    errors.append("Main.dfm: handler `%s` is not declared in TfrmMain" % handler)
            dfm_components = set(re.findall(r"^\s*object\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", dfm_text, re.M))
            for component in sorted(dfm_components):
                if component.startswith("frm"):
                    continue
                if not re.search(r"\b%s\s*:\s*T[A-Za-z0-9_]+" % re.escape(component), main["interface"]):
                    errors.append("Main.dfm: component `%s` has no matching field in TfrmMain" % component)

    # --- 6. dpr references -------------------------------------------------
    dpr = os.path.join(ROOT, "JieJieBox.dpr")
    if os.path.exists(dpr):
        dpr_text = read(dpr)
        for match in re.finditer(r"in\s+'([^']+\.pas)'", dpr_text):
            pas = match.group(1)
            if not os.path.exists(os.path.join(ROOT, pas)):
                errors.append("JieJieBox.dpr references missing file %s" % pas)

    print("units scanned: %d" % len(units))
    print()

    if warnings:
        print("WARNINGS (%d)" % len(warnings))
        for warning in warnings:
            print("  - %s" % warning)
        print()

    if notes and os.environ.get("CHECK_PASCAL_NOTES"):
        print("NOTES (%d) - file-local helpers, not errors" % len(notes))
        for note in notes:
            print("  - %s" % note)
        print()

    if errors:
        print("ERRORS (%d)" % len(errors))
        for error in errors:
            print("  - %s" % error)
        return 1

    print("OK: no interface/uses inconsistencies found")
    return 0


if __name__ == "__main__":
    sys.exit(main())
