import json
import os
import shutil
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareLinuxEngine as pl
import prepareRuntime as pr

INTERPRETER = "/lib64/ld-linux-x86-64.so.2"
LIBC = ("libc.so.6", ["GLIBC_2.34"])
NATIVE = "/opt/homebrew/opt/llvm/bin/llvm-readobj"
CLOSURE = "/Users/le/metascript/.scratch/managed-toolchain/transam/closure-modes"
RETAINED = {
    "needs": CLOSURE + "/shared-x64-parent-proof/fixture.so",
    "stub": "/Users/le/metascript/.scratch/managed-toolchain/transam/cpp-integration/consumer-proof/bundle with spaces"
            "/runtime/x86_64-linux-gnu.2.31/libc.so.6",
    "executable": "/Users/le/metascript/.scratch/managed-toolchain/transam/cpp-integration/consumer-proof/linuxSource.out",
    "runpath": CLOSURE + "/linux-engine-producer-review/verdef-parent.so",
    "oversized": CLOSURE + "/elf-reader-review/oversized-interpreter.elf",
}

ELF_LIB = r"""
import json, os
MARK = b"\n#FIELDS\n"
DEFAULTS = dict(type=3, machine=62, interpreter=None, needed=[], soname=None, runpath=None, rpath=None,
                verneed=[], verdef=[], elfClass=2, data=1)


def render(path, **given):
    f = dict(DEFAULTS)
    f.update(given)
    interp = b"" if f["interpreter"] is None else f["interpreter"].encode() + b"\0"
    body = b"\x7fELF" + bytes([f["elfClass"], f["data"], 1]) + b"\0" * 57 + interp + MARK + json.dumps(f).encode()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as handle:
        handle.write(body)


def fields(path):
    with open(path, "rb") as handle:
        data = handle.read()
    return json.loads(data[data.index(MARK) + len(MARK):])
"""
exec(ELF_LIB)
buildElf = render

INSPECTION_LIB = r"""
def inspection(args, path):
    f = fields(path)
    out = []
    if "--elf-output-style=JSON" in args:
        dynamic = [{"Tag": 1, "Type": "NEEDED", "Value": 1, "Library": n} for n in f["needed"]]
        if f["soname"] is not None:
            dynamic.append({"Tag": 14, "Type": "SONAME", "Value": 1, "Name": f["soname"]})
        for tag, key in ((15, "rpath"), (29, "runpath")):
            if f[key] is not None:
                dynamic.append({"Tag": tag, "Type": key.upper(), "Value": 1, "Path": f[key].split(":")})
        if f["verneed"]:
            dynamic += [{"Type": "VERNEED", "Value": 1}, {"Type": "VERNEEDNUM", "Value": len(f["verneed"])}]
        if f["verdef"]:
            dynamic += [{"Type": "VERDEF", "Value": 1}, {"Type": "VERDEFNUM", "Value": 1 + len(f["verdef"])}]
        if dynamic:
            dynamic.append({"Tag": 0, "Type": "NULL", "Value": 0})
        headers = []
        if f["interpreter"] is not None:
            headers.append({"ProgramHeader": {"Type": {"Name": "PT_INTERP", "Value": 3}, "Offset": 64,
                                              "FileSize": len(f["interpreter"]) + 1}})
        if dynamic:
            headers.append({"ProgramHeader": {"Type": {"Name": "PT_DYNAMIC", "Value": 2}, "Offset": 0, "FileSize": 0}})
        return json.dumps([{
            "ElfHeader": {"Ident": {"Class": {"Name": "64-bit", "Value": 2}, "DataEncoding": {"Name": "LittleEndian", "Value": 1}},
                          "Type": "SharedObject (0x%x)" % f["type"], "Machine": {"Name": "EM", "Value": f["machine"]}},
            "ProgramHeaders": headers, "DynamicSection": dynamic, "NeededLibraries": sorted(f["needed"])}])
    out.append("Version symbols section '.gnu.version' contains 1 entries:\n Addr: 0000000000000000  Offset: 0x000000  Link: 1 (.dynsym)\n  000:   0 (*local*)\n")
    if f["verdef"]:
        out.append("Version definition section '.gnu.version_d' contains %d entries:\n Addr: 0000000000000250  Offset: 0x000250  Link: 5 (.dynstr)" % (1 + len(f["verdef"])))
        out.append("  0x0000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: %s" % (f["soname"] or "x"))
        for index, name in enumerate(f["verdef"]):
            out.append("  0x%04x: Rev: 1  Flags: none  Index: %d  Cnt: 1  Name: %s" % (28 * (index + 1), index + 2, name))
        out.append("")
    if f["verneed"]:
        out.append("Version needs section '.gnu.version_r' contains %d entries:\n Addr: 0000000000000298  Offset: 0x000298  Link: 5 (.dynstr)" % len(f["verneed"]))
        for file, names in f["verneed"]:
            out.append("  0x0000: Version: 1  File: %s  Cnt: %d" % (file, len(names)))
            for name in names:
                out.append("  0x0020:   Name: %s  Flags: none  Version: 2" % name)
        out.append("")
    return "\n".join(out) + "\n"
"""
exec(INSPECTION_LIB)

FAKE_INSPECTOR = ("#!PYTHON\n" + ELF_LIB + INSPECTION_LIB + r"""
import sys
if sys.argv[1:] == ["--version"]:
    print("LLVM (http://llvm.org/):\n  LLVM version 21.1.8")
    sys.exit(0)
if os.environ.get("FAKE_INSPECTOR_FAILS"):
    sys.stderr.write("inspector: cannot read\n")
    sys.exit(1)
sys.stdout.write(inspection(sys.argv[1:-1], sys.argv[-1]))
""").replace("PYTHON", sys.executable)

REAL_INSPECT = pl.inspect


def inProcess(inspector, flags, path):
    """pl.inspect answering in process for a fake ELF inspector, which cannot be spawned; any other inspector runs for real."""
    with open(inspector, "rb") as f:
        fake = f.read(4) == b"\x7fELF"
    return inspection(list(flags), path) if fake else REAL_INSPECT(inspector, flags, path)


FAKE_PATCHELF = ("#!PYTHON\n" + ELF_LIB + r"""
import sys
args = sys.argv[1:]
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "calls.log"), "a") as log:
    log.write(" ".join(args) + "\n")
if args == ["--version"]:
    print("patchelf 0.18.0")
    sys.exit(0)
if args[0] == "--remove-rpath":
    path, change = args[1], {"runpath": None, "rpath": None}
elif args[0] == "--set-rpath":
    path, change = args[2], {"runpath": args[1], "rpath": None}
else:
    sys.exit("unexpected patchelf arguments %r" % args)
if os.environ.get("FAKE_PATCHELF_FAILS"):
    sys.exit("patchelf: cannot rewrite")
f = fields(path)
f.update(change)
render(path, **f)
""").replace("PYTHON", sys.executable)


def write(path, text="x\n", mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def read(path):
    with open(path) as f:
        return f.read()


def canned(path, jsonText="", gnuText="", code=0, stderr=""):
    """An inspector that answers every run with the given text, for the outputs a real tool must never give."""
    write(path, "#!%s\nimport sys\nsys.stderr.write(%r)\nsys.stdout.write(%r if 'JSON' in sys.argv[1] else %r)\nsys.exit(%d)\n" % (
        sys.executable, stderr, jsonText, gnuText, code), 0o755)
    return path


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareLinuxEngineTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def elf(self, path, mode=0o755, **fields):
        buildElf(path, **fields)
        os.chmod(path, mode)
        return path


class ElfReaderTest(TempCase):
    def setUp(self):
        super().setUp()
        self.inspector = self.path("tools", "llvm-readobj")
        write(self.inspector, FAKE_INSPECTOR, 0o755)

    def test_every_dynamic_fact_reaches_the_dict_that_closure_and_verification_read(self):
        given = dict(needed=["libb.so.1", "libc.so.6"], soname="liba.so.1", runpath="$ORIGIN/../lib:/opt/lib", rpath="/host/lib",
                     interpreter=INTERPRETER, verneed=[("libc.so.6", ["GLIBC_2.2.5", "GLIBC_2.34"]), ("libb.so.1", ["B_1"])],
                     verdef=["A_1", "A_2"], machine=62, type=3)
        info = pl.readElf(self.elf(self.path("a.so"), **given), self.inspector)
        self.assertEqual(info, dict(given, verneed=[(f, n) for f, n in given["verneed"]]))
        self.assertEqual(sorted(info), sorted(("type", "machine", "interpreter", "needed", "soname", "runpath", "rpath", "verneed", "verdef")))

    def test_an_object_without_dynamic_data_reads_as_empty(self):
        info = pl.readElf(self.elf(self.path("plain"), type=2), self.inspector)
        self.assertEqual(info, dict(type=2, machine=62, interpreter=None, needed=[], soname=None, runpath=None, rpath=None,
                                    verneed=[], verdef=[]))

    def test_a_file_that_is_not_elf_reads_as_none_without_running_the_inspector(self):
        write(self.path("script"), "#!/bin/sh\n")
        write(self.path("empty"), "")
        with mock.patch.object(pl.subprocess, "run", side_effect=AssertionError("inspector run")):
            self.assertIsNone(pl.readElf(self.path("script"), self.inspector))
            self.assertIsNone(pl.readElf(self.path("empty"), self.inspector))

    def test_32_bit_and_big_endian_files_are_refused_from_the_header_before_any_inspector_run(self):
        self.elf(self.path("elf32"), elfClass=1)
        self.elf(self.path("big"), data=2)
        write(self.path("short"), "\x7fELF\x02")
        with mock.patch.object(pl.subprocess, "run", side_effect=AssertionError("inspector run")):
            for name in ("elf32", "big", "short"):
                with self.assertRaisesRegex(pe.EngineError, "not a 64-bit little-endian ELF"):
                    pl.readElf(self.path(name), self.inspector)

    def test_an_inspector_that_fails_or_warns_is_an_error_naming_the_file(self):
        path = self.elf(self.path("a.so"))
        with mock.patch.dict(os.environ, {"FAKE_INSPECTOR_FAILS": "1"}):
            with self.assertRaisesRegex(pe.EngineError, r"a\.so: llvm-readobj failed \(1\): inspector: cannot read"):
                pl.readElf(path, self.inspector)
        warning = canned(self.path("tools", "warns"), jsonText="[]", stderr="warning: truncated dynamic table\n")
        with self.assertRaisesRegex(pe.EngineError, r"a\.so: warns warned: warning: truncated dynamic table"):
            pl.readElf(path, warning)

    def test_the_inspector_is_run_with_exactly_the_json_flags_then_the_gnu_version_flags(self):
        path = self.elf(self.path("a.so"))
        with mock.patch.object(pl.subprocess, "run", wraps=pl.subprocess.run) as run:
            pl.readElf(path, self.inspector)
        self.assertEqual([c.args[0] for c in run.call_args_list], [
            [self.inspector, "--elf-output-style=JSON", "--file-headers", "--program-headers", "--dynamic-table", "--needed-libs", path],
            [self.inspector, "--elf-output-style=GNU", "--version-info", path]])


class RealToolTest(TempCase):
    """The reader against the native llvm-readobj on retained real ELF files."""
    def setUp(self):
        super().setUp()
        if not os.access(NATIVE, os.X_OK):
            self.skipTest("no native llvm-readobj on this machine")

    def read(self, name):
        if not os.path.exists(RETAINED[name]):
            self.skipTest("retained %s is not on this machine" % name)
        return pl.readElf(RETAINED[name], NATIVE)

    def test_the_parent_type_fixtures_name_their_type_and_role_but_are_not_claimed_to_be_complete_objects(self):
        directory = CLOSURE + "/linux-audit-edgecases/elf-type-%d.so"
        if not all(os.path.exists(directory % n) for n in (1, 3, 4)):
            self.skipTest("retained elf-type fixtures are not on this machine")
        info = {n: pl.readElf(directory % n, NATIVE) for n in (1, 3, 4)}
        self.assertEqual({n: i["type"] for n, i in info.items()}, {1: 1, 3: 3, 4: 4})
        for kind, name in ((1, "ET_REL"), (4, "ET_CORE")):
            self.assertEqual(pl.roleProblem("bin/x", info[kind]), "ELF type %d (%s) is not ET_EXEC or ET_DYN, required of bin/x" % (kind, name))
            self.assertEqual(pl.roleProblem("lib/x.so", info[kind]), "ELF type %d (%s) is not ET_DYN, required of lib/x.so" % (kind, name))
        self.assertEqual(pl.roleProblem("bin/x", info[3]), "has no interpreter")
        self.assertEqual(pl.roleProblem("lib/x.so", info[3]), "soname is None, not x.so")

    def test_a_zig_shared_object_reports_its_version_needs(self):
        info = self.read("needs")
        self.assertEqual((info["type"], info["machine"], info["interpreter"], info["needed"]), (3, 62, None, ["libc.so.6", "libpthread.so.0"]))
        self.assertEqual(info["verneed"], [("libc.so.6", ["GLIBC_2.2.5"]), ("libpthread.so.0", ["GLIBC_2.2.5"])])
        self.assertEqual((info["verdef"], info["soname"], info["runpath"]), ([], None, None))

    def test_a_linked_executable_reports_its_interpreter_and_every_needed_file(self):
        info = self.read("executable")
        self.assertEqual((info["type"], info["interpreter"]), (2, INTERPRETER))
        self.assertEqual(info["needed"], ["libc.so.6", "ld-linux-x86-64.so.2", "libpthread.so.0", "libdl.so.2"])
        self.assertEqual([f for f, _ in info["verneed"]], ["libc.so.6", "ld-linux-x86-64.so.2", "libpthread.so.0", "libdl.so.2"])
        self.assertEqual(dict(info["verneed"])["libc.so.6"], ["GLIBC_2.2.5", "GLIBC_2.3.2", "GLIBC_2.7", "GLIBC_2.9", "GLIBC_2.16", "GLIBC_2.17"])

    def test_the_glibc_stub_reports_its_soname_and_every_version_it_defines_except_the_base(self):
        info = self.read("stub")
        self.assertEqual((info["soname"], len(info["verdef"]), info["needed"]), ("libc.so.6", 44, []))
        self.assertEqual(info["verdef"][:3], ["GLIBC_2.0", "GLIBC_2.1", "GLIBC_2.1.1"])
        self.assertNotIn("libc.so.6", info["verdef"])

    def test_a_library_with_a_runpath_and_two_version_definitions_reports_both(self):
        info = self.read("runpath")
        self.assertEqual((info["soname"], info["runpath"], info["rpath"], info["verdef"]), ("libx.so.1", "$ORIGIN/../lib", None, ["V1", "V2"]))

    def test_an_interpreter_size_of_two_to_the_63_is_refused_naming_the_bound(self):
        if not os.path.exists(RETAINED["oversized"]):
            self.skipTest("retained oversized interpreter fixture is not on this machine")
        with self.assertRaisesRegex(pe.EngineError, r"PT_INTERP at 232, 9223372036854775808 bytes, is not inside the file"):
            pl.readElf(RETAINED["oversized"], NATIVE)

    def test_the_native_json_of_a_file_with_version_definitions_is_not_valid_json(self):
        if not os.path.exists(RETAINED["stub"]):
            self.skipTest("retained stub is not on this machine")
        done = pl.subprocess.run([NATIVE, "--elf-output-style=JSON", "--version-info", RETAINED["stub"]],
                                 stdout=pl.subprocess.PIPE, universal_newlines=True)
        with self.assertRaises(json.JSONDecodeError):
            json.loads(done.stdout)
        with self.assertRaisesRegex(pe.EngineError, "inspector output is not JSON"):
            pl.readElf(RETAINED["stub"], canned(self.path("raw"), jsonText=done.stdout))


INV10 = CLOSURE + "/windows-wsl-inventory/inv10/gnu.%s.out"
INV10_SHA256 = {"libLLVM.so.21.1": "ca787f1bbbe5d43affb17638c05df1b5ac5d59ccb3fd145429ca12e82883d259",
                "libstdc++.so.6.0.35": "5a145e70b957b2410d1deab2898bebb705bcb956bd00bbc502740b82a9b61d2c"}


class RealGnuTextTest(TempCase):
    """readVersions on the raw `--elf-output-style=GNU --version-info` text of installed LLVM 21.1.8 (WSL libLLVM and GNU ld libstdc++)."""
    def raw(self, name):
        path = INV10 % name
        if not os.path.exists(path):
            self.skipTest("retained inv10 capture %s is not on this machine" % name)
        self.assertEqual(pe.sha256File(path), INV10_SHA256[name])
        with open(path, encoding="utf-8") as f:
            return f.read()

    def test_libllvm_reads_seven_needs_files_forty_seven_names_and_one_non_base_definition(self):
        needs, defs = pl.readVersions("libLLVM", self.raw("libLLVM.so.21.1"), 7, 2)
        self.assertEqual((len(needs), sum(len(n) for _, n in needs), defs), (7, 47, ["LLVM_21.1"]))

    def test_libstdcxx_reads_every_definition_with_its_parent_line(self):
        needs, defs = pl.readVersions("libstdc++", self.raw("libstdc++.so.6.0.35"), 4, 56)
        self.assertEqual((len(needs), len(defs), defs[:3], len(set(defs))), (4, 55, ["GLIBCXX_3.4", "GLIBCXX_3.4.1", "GLIBCXX_3.4.2"], 55))
        self.assertIn("GLIBCXX_3.4.30", defs)

    def test_libstdcxx_with_a_parent_line_removed_or_a_count_changed_is_refused(self):
        lines = self.raw("libstdc++.so.6.0.35").splitlines(keepends=True)
        parent = next(i for i, l in enumerate(lines) if "Parent 1:" in l)
        without = "".join(lines[:parent] + lines[parent + 1:])
        with self.assertRaisesRegex(pe.EngineError, "missing 1 parent lines before"):
            pl.readVersions("libstdc++", without, 4, 56)
        with self.assertRaisesRegex(pe.EngineError, "version definition: dynamic table says 55"):
            pl.readVersions("libstdc++", "".join(lines), 4, 55)


def document(**over):
    """The inspector JSON of a minimal dynamic executable, with sections replaced by over."""
    base = {"ElfHeader": {"Ident": {"Class": {"Value": 2}, "DataEncoding": {"Value": 1}}, "Type": "SharedObject (0x3)",
                          "Machine": {"Value": 62}},
            "ProgramHeaders": [{"ProgramHeader": {"Type": {"Name": "PT_INTERP"}, "Offset": 64, "FileSize": len(INTERPRETER) + 1}},
                               {"ProgramHeader": {"Type": {"Name": "PT_DYNAMIC"}, "Offset": 0, "FileSize": 0}}],
            "DynamicSection": [{"Type": "NEEDED", "Library": "libc.so.6"}, {"Type": "SONAME", "Name": "x"},
                               {"Type": "RUNPATH", "Path": ["$ORIGIN"]}, {"Type": "NULL"}],
            "NeededLibraries": ["libc.so.6"]}
    base.update(over)
    return base


NEEDS = ("Version needs section '.gnu.version_r' contains 1 entries:\n Addr: 0000000000000298  Offset: 0x000298  Link: 5 (.dynstr)\n"
         "  0x0000: Version: 1  File: libc.so.6  Cnt: 1\n  0x0020:   Name: GLIBC_2.2.5  Flags: none  Version: 2\n\n")
DEFS = ("Version definition section '.gnu.version_d' contains 2 entries:\n Addr: 0000000000000250  Offset: 0x000250  Link: 5 (.dynstr)\n"
        "  0x0000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: x\n  0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: V1\n\n")


class MalformedInspectionTest(TempCase):
    def setUp(self):
        super().setUp()
        self.file = self.elf(self.path("a.so"), interpreter=INTERPRETER)

    def read(self, doc, gnu="", mutate=None, raw=None):
        if mutate:
            mutate(doc)
        return pl.readElf(self.file, canned(self.path("tools", "canned"), jsonText=raw if raw is not None else json.dumps([doc]), gnuText=gnu))

    def refused(self, pattern, doc=None, **kwargs):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.read(doc or document(), **kwargs)

    def test_the_minimal_document_reads_cleanly(self):
        self.assertEqual(self.read(document())["interpreter"], INTERPRETER)

    def test_interpreter_bounds_come_from_the_file_not_from_the_inspector(self):
        size = os.path.getsize(self.file)
        for offset, length in ((64, 2 ** 63), (64, 4097), (64, 0), (size - 3, 28), (-1, 28), (2 ** 63, 28)):
            doc = document()
            doc["ProgramHeaders"][0]["ProgramHeader"].update(Offset=offset, FileSize=length)
            with self.subTest(offset=offset, length=length):
                self.refused("PT_INTERP at %d, %d bytes, is not inside the file or is over 4096 bytes" % (offset, length), doc)

    def test_an_interpreter_that_is_not_one_nul_terminated_utf8_path_is_refused(self):
        for body, text in ((INTERPRETER.encode(), "one NUL-terminated"), (b"/a\0b\0", "one NUL-terminated"), (b"/\xff\xfe\0", "not UTF-8")):
            with open(self.file, "r+b") as f:
                f.seek(64)
                f.write(body + b"\0" * 0)
            doc = document()
            doc["ProgramHeaders"][0]["ProgramHeader"]["FileSize"] = len(body)
            with self.subTest(body=body):
                self.refused(text, doc)

    def test_a_second_interpreter_or_dynamic_header_is_refused(self):
        for index, name in ((0, "PT_INTERP"), (1, "PT_DYNAMIC")):
            doc = document()
            doc["ProgramHeaders"].append(dict(doc["ProgramHeaders"][index]))
            with self.subTest(name):
                self.refused("has 2 %s program headers" % name, doc)

    def test_a_dynamic_table_without_a_dynamic_header_is_refused(self):
        doc = document()
        doc["ProgramHeaders"] = doc["ProgramHeaders"][:1]
        self.refused("dynamic table the program headers do not have", doc)

    def test_a_critical_dynamic_tag_given_twice_is_refused(self):
        for entry in ({"Type": "SONAME", "Name": "y"}, {"Type": "RUNPATH", "Path": ["/x"]}, {"Type": "RPATH", "Path": ["/a"]},
                      {"Type": "STRTAB"}, {"Type": "VERNEED"}, {"Type": "VERNEEDNUM", "Value": 1}, {"Type": "VERDEF"},
                      {"Type": "VERDEFNUM", "Value": 1}):
            doc = document()
            doc["DynamicSection"][-1:-1] = [dict(entry), dict(entry)] if entry["Type"] not in ("SONAME", "RUNPATH") else [dict(entry)]
            with self.subTest(entry["Type"]):
                self.refused("dynamic table has 2 %s entries" % entry["Type"], doc)

    def test_needed_entries_must_equal_the_needed_libraries_the_inspector_lists(self):
        for listed in ([], ["libc.so.6", "libm.so.6"], ["libm.so.6"], "libc.so.6", [5]):
            doc = document(NeededLibraries=listed)
            with self.subTest(listed=listed):
                self.refused("NEEDED entries and NeededLibraries disagree", doc)

    def test_version_counts_of_the_dynamic_table_must_equal_the_sections_the_inspector_prints(self):
        for label, dynamic, gnu in (
                ("needs tag with no section", [{"Type": "VERNEEDNUM", "Value": 1}], ""),
                ("needs section with no tag", [], NEEDS),
                ("needs tag of two, section of one", [{"Type": "VERNEEDNUM", "Value": 2}], NEEDS),
                ("defs tag with no section", [{"Type": "VERDEFNUM", "Value": 2}], ""),
                ("defs section with no tag", [], DEFS),
                ("defs tag of three, section of two", [{"Type": "VERDEFNUM", "Value": 3}], DEFS)):
            doc = document()
            doc["DynamicSection"][-1:-1] = dynamic
            with self.subTest(label):
                self.refused("version (needs|definition): dynamic table says", doc, gnu=gnu)

    def test_matching_version_sections_are_read_and_the_definition_base_is_left_out(self):
        doc = document()
        doc["DynamicSection"][-1:-1] = [{"Type": "VERNEEDNUM", "Value": 1}, {"Type": "VERDEFNUM", "Value": 2}]
        info = self.read(doc, gnu=NEEDS + DEFS)
        self.assertEqual((info["verneed"], info["verdef"]), ([("libc.so.6", ["GLIBC_2.2.5"])], ["V1"]))

    def test_unrecognized_or_inconsistent_version_text_is_refused(self):
        doc = lambda n, d: document(DynamicSection=document()["DynamicSection"][:-1] + (
            [{"Type": "VERNEEDNUM", "Value": n}] if n else []) + ([{"Type": "VERDEFNUM", "Value": d}] if d else []) + [{"Type": "NULL"}])
        for label, text, count in (
                ("stray line", "garbage\n", (0, 0)),
                ("needs name before file", NEEDS.replace("  0x0000: Version: 1  File: libc.so.6  Cnt: 1\n", ""), (1, 0)),
                ("needs count", NEEDS.replace("Cnt: 1", "Cnt: 2"), (1, 0)),
                ("needs line", NEEDS.replace("Flags: none", "Flagz"), (1, 0)),
                ("definition line", DEFS.replace("Index: 2", "Idx: 2"), (0, 2)),
                ("definition with an inline parent", DEFS.replace("Name: V1", "Name: V1  Parent 1: V0"), (0, 2)),
                ("definition of zero names", DEFS.replace("Cnt: 1  Name: V1", "Cnt: 0  Name: V1"), (0, 2)),
                ("two definition sections", DEFS + DEFS, (0, 2))):
            with self.subTest(label):
                self.refused("unrecognized version|version needs of|two definition sections|version definition: dynamic", doc(*count), gnu=text)

    def withDefinitions(self, lines):
        doc = document()
        doc["DynamicSection"][-1:-1] = [{"Type": "VERDEFNUM", "Value": 3}]
        head = DEFS.split("\n  0x0000")[0].replace("contains 2", "contains 3")
        return doc, head + "\n" + "\n".join(lines) + "\n\n"

    BASE = "  0x0000: Rev: 1  Flags: BASE  Index: 1  Cnt: 1  Name: x"
    V1 = "  0x001c: Rev: 1  Flags: none  Index: 2  Cnt: 1  Name: GLIBCXX_3.4"
    V2 = "  0x0038: Rev: 1  Flags: none  Index: 3  Cnt: 2  Name: GLIBCXX_3.4.1"
    P1 = "  0x0054: Parent 1: GLIBCXX_3.4"

    def test_a_definition_whose_parents_follow_on_the_next_lines_is_read_in_the_captured_gnu_shape(self):
        doc, text = self.withDefinitions([self.BASE, self.V1, self.V2, self.P1])
        self.assertEqual(self.read(doc, gnu=text)["verdef"], ["GLIBCXX_3.4", "GLIBCXX_3.4.1"])

    def test_a_definition_of_two_parents_needs_both_in_order(self):
        three = self.V2.replace("Cnt: 2", "Cnt: 3")
        doc, text = self.withDefinitions([self.BASE, self.V1, three, self.P1, "  0x005c: Parent 2: GLIBCXX_3.4.1"])
        self.assertEqual(self.read(doc, gnu=text)["verdef"], ["GLIBCXX_3.4", "GLIBCXX_3.4.1"])
        for label, lines, pattern in (
                ("second parent missing", [self.BASE, self.V1, three, self.P1], "missing 1 parent lines"),
                ("second parent after another definition", [self.BASE, self.V1, three, self.P1, self.V1], "missing 1 parent lines before"),
                ("parents swapped", [self.BASE, self.V1, three, "  0x005c: Parent 2: GLIBCXX_3.4.1", self.P1], "parent 2 out of order"),
                ("parent numbered twice", [self.BASE, self.V1, three, self.P1, self.P1], "parent 1 out of order")):
            doc, text = self.withDefinitions(lines)
            with self.subTest(label):
                self.refused(pattern, doc, gnu=text)

    def test_parent_lines_that_are_missing_extra_or_malformed_are_refused(self):
        for label, lines, pattern in (
                ("parent missing at the end of the section", [self.BASE, self.V1, self.V2], "missing 1 parent lines"),
                ("parent missing before the next definition", [self.BASE, self.V2, self.V1], "missing 1 parent lines before"),
                ("parent beyond Cnt", [self.BASE, self.V1, self.P1], "parent 1 out of order or beyond Cnt"),
                ("parent before any definition", [self.P1, self.BASE, self.V1], "parent 1 out of order or beyond Cnt"),
                ("parent without a name", [self.BASE, self.V1, self.V2, "  0x0054: Parent 1:"], "missing 1 parent lines before|unrecognized version definition line"),
                ("parent without a number", [self.BASE, self.V1, self.V2, "  0x0054: Parent: GLIBCXX_3.4"], "missing 1 parent lines before")):
            doc, text = self.withDefinitions(lines)
            with self.subTest(label):
                self.refused(pattern, doc, gnu=text)

    def test_a_definition_text_that_ends_inside_the_parents_is_refused_without_a_trailing_blank_line(self):
        doc, text = self.withDefinitions([self.BASE, self.V1, self.V2])
        self.refused("missing 1 parent lines at the end of the text", doc, gnu=text.rstrip("\n"))

    def test_missing_or_mistyped_inspector_fields_are_refused_naming_the_field(self):
        cases = (
            ("ElfHeader", lambda d: d.pop("ElfHeader"), "no ElfHeader dict"),
            ("Ident", lambda d: d["ElfHeader"].pop("Ident"), "no ElfHeader.Ident dict"),
            ("Machine", lambda d: d["ElfHeader"].pop("Machine"), "no ElfHeader.Machine dict"),
            ("Machine value", lambda d: d["ElfHeader"]["Machine"].update(Value="62"), "no Machine.Value int"),
            ("Machine bool", lambda d: d["ElfHeader"]["Machine"].update(Value=True), "no Machine.Value int"),
            ("Type", lambda d: d["ElfHeader"].update(Type="SharedObject"), "ElfHeader.Type has no numeric value"),
            ("Type text", lambda d: d["ElfHeader"].update(Type=3), "no ElfHeader.Type str"),
            ("ProgramHeaders", lambda d: d.pop("ProgramHeaders"), "no ProgramHeaders list"),
            ("ProgramHeader", lambda d: d["ProgramHeaders"].append({}), "no ProgramHeaders entry dict"),
            ("PT name", lambda d: d["ProgramHeaders"][0]["ProgramHeader"].pop("Type"), "no ProgramHeader.Type dict"),
            ("interp offset", lambda d: d["ProgramHeaders"][0]["ProgramHeader"].pop("Offset"), "no PT_INTERP Offset int"),
            ("interp size", lambda d: d["ProgramHeaders"][0]["ProgramHeader"].update(FileSize="28"), "no PT_INTERP FileSize int"),
            ("dynamic type", lambda d: d["DynamicSection"][0].pop("Type"), "no DynamicSection Type str"),
            ("dynamic list", lambda d: d.update(DynamicSection={}), "dynamic table the program headers do not have"),
            ("needed library", lambda d: d["DynamicSection"][0].pop("Library"), "no NEEDED Library str"),
            ("soname", lambda d: d["DynamicSection"][1].pop("Name"), "no SONAME Name str"),
            ("runpath", lambda d: d["DynamicSection"][2].update(Path="$ORIGIN"), "no RUNPATH Path list"),
            ("runpath entries", lambda d: d["DynamicSection"][2].update(Path=[1]), "RUNPATH Path is not a list of strings"),
            ("verneednum", lambda d: d["DynamicSection"].insert(0, {"Type": "VERNEEDNUM"}), "no VERNEEDNUM Value int"))
        for label, edit, text in cases:
            doc = document()
            edit(doc)
            with self.subTest(label):
                self.refused(text, doc)

    def test_a_class_or_byte_order_other_than_the_file_header_is_refused(self):
        for key in ("Class", "DataEncoding"):
            doc = document()
            doc["ElfHeader"]["Ident"][key]["Value"] = 1 if key == "Class" else 2
            with self.subTest(key):
                self.refused("another class or byte order than the file header", doc)

    def test_output_that_is_not_one_json_document_is_refused(self):
        self.refused("inspector output is not JSON", raw="[{")
        self.refused("inspector output is not JSON", raw="")
        self.refused("inspector JSON is not one document", raw="[]")
        self.refused("inspector JSON is not one document", raw="{}")
        self.refused("inspector JSON is not one document", raw=json.dumps([document(), document()]))
        self.refused("no ElfHeader dict", raw="[1]")


class LimitTest(TempCase):
    def problem(self, **given):
        return pl.limitProblem(dict(DEFAULTS, **given))

    def test_the_baseline_is_glibc_2_39(self):
        self.assertEqual(pl.GLIBC_BASELINE, (2, 39))

    def test_glibc_versions_up_to_the_baseline_pass_and_above_are_refused(self):
        for names in (["GLIBC_2.2.5"], ["GLIBC_2.38", "GLIBC_2.39"]):
            self.assertIsNone(self.problem(needed=["libc.so.6"], verneed=[("libc.so.6", names)]), msg=names)
        for names, text in ((["GLIBC_2.40"], "GLIBC_2.40"), (["GLIBC_2.42"], "GLIBC_2.42"), (["GLIBC_2.39.1"], "GLIBC_2.39.1")):
            self.assertIn("above the 2.39 baseline", self.problem(needed=["libc.so.6"], verneed=[("libc.so.6", names)]))
            self.assertIn(text, self.problem(needed=["libc.so.6"], verneed=[("libc.so.6", names)]))

    def test_glibc_private_and_other_names_under_a_system_library_are_refused(self):
        for name in ("GLIBC_PRIVATE", "GLIBCXX_3.4", "NOTGLIBC_2.1"):
            self.assertIn("is not a versioned GLIBC symbol", self.problem(verneed=[("libc.so.6", [name])]), msg=name)

    def test_every_system_library_is_checked_and_a_bundled_library_is_not(self):
        self.assertIn("libm.so.6", self.problem(verneed=[("libm.so.6", ["GLIBC_2.41"])]))
        self.assertIn("ld-linux-x86-64.so.2", self.problem(verneed=[("ld-linux-x86-64.so.2", ["GLIBC_PRIVATE"])]))
        self.assertIsNone(self.problem(verneed=[("libstdc++.so.6", ["GLIBCXX_3.4.30"])]))

    def test_other_machines_and_interpreters_are_refused(self):
        self.assertIn("machine 183", self.problem(machine=183))
        self.assertIn("machine 3", self.problem(machine=3))
        self.assertIn("interpreter /lib/ld-musl-x86_64.so.1", self.problem(interpreter="/lib/ld-musl-x86_64.so.1"))
        self.assertIsNone(self.problem(interpreter=INTERPRETER))


class World(TempCase):
    """A fake Debian-like host: LLVM under an install root, libraries under a host root, one package per library."""
    owners = {"libLLVM.so.21.1": "libllvm21", "libclang-cpp.so.21.1": "libclang-cpp21", "libstdc++.so.6": "libstdc++6",
              "libgcc_s.so.1": "libgcc-s1", "libedit.so.2": "libedit2", "libtinfo.so.6": "libtinfo6"}

    def setUp(self):
        super().setUp()
        self.host = self.path("host")
        self.llvm = self.path("usr", "lib", "llvm-21")
        self.hostLibs = os.path.join(self.host, "usr", "lib", "x86_64-linux-gnu")
        self.docs = self.path("docs")
        self.versions = {"clang": "21.1.8", "ld.lld": "21.1.8", "llvm-readobj": "21.1.8"}
        self.makeInstall()
        self.makeHostLibraries()
        self.patchelf = self.path("tools", "patchelf")
        write(self.patchelf, FAKE_PATCHELF, 0o755)
        self.inspector = os.path.join(self.llvm, "bin", "llvm-readobj")
        self.patchers = (mock.patch.object(pl, "HOST_ROOT", self.host),
                         mock.patch.object(pl, "inspect", side_effect=inProcess),
                         mock.patch.object(pl, "hostPackageOwners", side_effect=self.hostPackageOwners),
                         mock.patch.object(pl, "hostPackage", side_effect=self.hostPackage),
                         mock.patch.object(pe, "toolVersion", side_effect=self.toolVersion),
                         mock.patch.object(pl, "detectHost", return_value=pe.LINUX_X64))
        for patcher in self.patchers:
            patcher.start()
            self.addCleanup(patcher.stop)

    def toolVersion(self, binary, pattern):
        return self.versions[os.path.basename(binary)]

    def hostPackageOwners(self, paths):
        return {p: [self.owners.get(os.path.basename(p)) or (
            "libclang-common-21-dev" if "/lib/clang/" in p else "llvm-21")] for p in paths}

    def hostPackage(self, name):
        copyright = os.path.join(self.docs, name, "copyright")
        write(copyright, "copyright of %s\n" % name)
        return "%s-1" % name, copyright

    def makeInstall(self):
        tool = dict(needed=["libLLVM.so.21.1", "libc.so.6"], interpreter=INTERPRETER, runpath="$ORIGIN/../lib",
                    verneed=[LIBC])
        self.elf(os.path.join(self.llvm, "bin", "clang"), **dict(tool, needed=[
            "libclang-cpp.so.21.1", "libLLVM.so.21.1", "libstdc++.so.6", "libm.so.6", "libc.so.6"],
            verneed=[("libstdc++.so.6", ["GLIBCXX_3.4.30"]), LIBC]))
        for name in ("lld", "llvm-ar", "llvm-ranlib", "llvm-strip", "llvm-objcopy", "llvm-nm", "dsymutil", "llvm-readobj"):
            self.elf(os.path.join(self.llvm, "bin", name), **tool)
        os.symlink("lld", os.path.join(self.llvm, "bin", "ld.lld"))
        self.elf(os.path.join(self.llvm, "lib", "libclang-cpp.so.21.1"), mode=0o644, soname="libclang-cpp.so.21.1",
                 needed=["libLLVM.so.21.1", "libstdc++.so.6", "libc.so.6"], runpath="$ORIGIN/../lib", verneed=[LIBC])
        write(os.path.join(self.llvm, "lib", "clang", "21", "include", "stddef.h"), "stddef\n")
        write(os.path.join(self.llvm, "lib", "clang", "21", "lib", "linux", "libclang_rt.builtins-x86_64.a"), "!<arch>\n")

    def library(self, directory, name, **fields):
        fields.setdefault("soname", name)
        fields.setdefault("needed", ["libc.so.6"])
        fields.setdefault("verneed", [LIBC])
        return self.elf(os.path.join(directory, name), mode=0o644, **fields)

    def makeHostLibraries(self):
        self.library(self.hostLibs, "libLLVM.so.21.1", needed=["libedit.so.2", "libm.so.6", "libc.so.6"],
                     verneed=[("libc.so.6", ["GLIBC_2.38"])])
        self.library(self.hostLibs, "libstdc++.so.6", needed=["libm.so.6", "libgcc_s.so.1", "libc.so.6"],
                     verdef=["GLIBCXX_3.4.30"], verneed=[("libc.so.6", ["GLIBC_2.38"])])
        self.library(self.hostLibs, "libgcc_s.so.1", verneed=[("libc.so.6", ["GLIBC_2.35"])])
        self.library(self.hostLibs, "libedit.so.2", needed=["libtinfo.so.6", "libc.so.6"],
                     verneed=[("libtinfo.so.6", ["NCURSES6_TINFO_5.0.19991023"]), ("libc.so.6", ["GLIBC_2.42"])])
        self.library(self.hostLibs, "libtinfo.so.6", verdef=["NCURSES6_TINFO_5.0.19991023"],
                     verneed=[("libc.so.6", ["GLIBC_2.33"])])

    def overrideRoot(self, name="edit-root", package="libedit2", version="3.1-20230828-1build1", glibc="GLIBC_2.38"):
        root = self.path(name)
        shutil.rmtree(root, ignore_errors=True)
        write(os.path.join(root, "DEBIAN", "control"), "Package: %s\nVersion: %s\nArchitecture: amd64\n" % (package, version))
        write(os.path.join(root, "usr", "share", "doc", package, "copyright"), "copyright of %s %s\n" % (package, version))
        directory = os.path.join(root, "usr", "lib", "x86_64-linux-gnu")
        self.library(directory, "libedit.so.2.0.72", soname="libedit.so.2", needed=["libtinfo.so.6", "libc.so.6"],
                     verneed=[("libtinfo.so.6", ["NCURSES6_TINFO_5.0.19991023"]), ("libc.so.6", [glibc])])
        os.symlink("libedit.so.2.0.72", os.path.join(directory, "libedit.so.2"))
        return root

    def prepare(self, output=None, libraryDirs=(), patchelf=None, llvm=None, lld=None):
        return pl.prepareEngine(llvm or self.llvm, lld or self.llvm, output or self.path("out", "engine"),
                                list(libraryDirs), patchelf or self.patchelf)

    def calls(self):
        log = os.path.join(os.path.dirname(self.patchelf), "calls.log")
        return read(log).splitlines() if os.path.exists(log) else []

    def tree(self, root):
        return {os.path.relpath(os.path.join(d, n), root): (os.readlink(os.path.join(d, n)) if os.path.islink(os.path.join(d, n))
                                                            else pe.sha256File(os.path.join(d, n)))
                for d, _, names in os.walk(root) for n in names}


class Builder(World):
    def runTest(self):
        pass


_built = []


def built():
    """One prepared bundle with its fake world, made once for the tests that only read it."""
    if not _built:
        world = Builder()
        world.setUp()
        world.root = world.overrideRoot()
        world.sources = {"llvm": world.tree(world.llvm), "host": world.tree(world.host), "root": world.tree(world.root)}
        world.out = world.path("out", "engine")
        world.result = world.prepare(libraryDirs=[world.root])
        for patcher in world.patchers:
            patcher.stop()
        _built.append(world)
    return _built[0]


def tearDownModule():
    for world in _built:
        world.doCleanups()


class ClosureTest(World):
    def test_a_host_library_above_the_baseline_is_refused_before_any_output_when_no_override_is_given(self):
        with self.assertRaisesRegex(pe.EngineError, r"libedit\.so\.2: .*GLIBC_2\.42.*above the 2\.39 baseline"):
            self.prepare()
        self.assertFalse(os.path.lexists(self.path("out")))

    def test_an_override_root_replaces_the_host_library_and_the_rest_of_the_closure_comes_from_the_host(self):
        root = self.overrideRoot()
        out, (host, version, count), plan, records = self.prepare(libraryDirs=[root])
        self.assertEqual((host, version), (pe.LINUX_X64, "21.1.8"))
        self.assertEqual(plan["lib/libedit.so.2"], os.path.join(root, "usr", "lib", "x86_64-linux-gnu", "libedit.so.2.0.72"))
        self.assertEqual(plan["lib/libtinfo.so.6"], os.path.join(self.hostLibs, "libtinfo.so.6"))
        self.assertEqual(plan["lib/libclang-cpp.so.21.1"], os.path.join(self.llvm, "lib", "libclang-cpp.so.21.1"))
        self.assertEqual(sorted(n for n in plan if n.startswith("lib/") and not n.startswith("lib/clang/")), [
            "lib/libLLVM.so.21.1", "lib/libclang-cpp.so.21.1", "lib/libedit.so.2", "lib/libgcc_s.so.1",
            "lib/libstdc++.so.6", "lib/libtinfo.so.6"])

    def test_an_override_that_is_itself_above_the_baseline_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, r"libedit\.so\.2\.0\.72: .*GLIBC_2\.41"):
            self.prepare(libraryDirs=[self.overrideRoot(glibc="GLIBC_2.41")])

    def test_the_first_explicit_root_wins_over_a_later_one_and_over_the_host(self):
        first, second = self.overrideRoot("first", version="1"), self.overrideRoot("second", version="2")
        _, _, plan, records = self.prepare(libraryDirs=[first, second])
        self.assertTrue(plan["lib/libedit.so.2"].startswith(first))
        self.assertEqual([r["version"] for r in records if r["name"] == "libedit2"], ["1"])

    def test_a_runpath_directory_beats_the_host_directories(self):
        self.library(self.hostLibs, "libclang-cpp.so.21.1", needed=["libc.so.6"], verneed=[("libc.so.6", ["GLIBC_2.42"])])
        _, _, plan, _ = self.prepare(libraryDirs=[self.overrideRoot()])
        self.assertEqual(plan["lib/libclang-cpp.so.21.1"], os.path.join(self.llvm, "lib", "libclang-cpp.so.21.1"))

    def test_a_dependency_found_nowhere_is_refused_naming_it_and_the_object_that_needs_it(self):
        os.remove(os.path.join(self.hostLibs, "libgcc_s.so.1"))
        with self.assertRaisesRegex(pe.EngineError, r"libstdc\+\+\.so\.6: cannot find libgcc_s\.so\.1"):
            self.prepare(libraryDirs=[self.overrideRoot()])
        self.assertFalse(os.path.lexists(self.path("out")))

    def test_a_library_whose_soname_is_not_the_name_it_was_found_by_is_refused(self):
        self.library(self.hostLibs, "libtinfo.so.6", soname="libtinfo.so.5", verdef=["NCURSES6_TINFO_5.0.19991023"])
        with self.assertRaisesRegex(pe.EngineError, "libtinfo.so.6: soname is libtinfo.so.5"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_system_library_is_never_bundled_even_when_the_host_has_it(self):
        self.library(self.hostLibs, "libc.so.6")
        self.library(self.hostLibs, "libm.so.6")
        _, _, plan, _ = self.prepare(libraryDirs=[self.overrideRoot()])
        self.assertEqual([n for n in plan if n.split("/")[-1] in pl.SYSTEM_LIBRARIES], [])

    def test_two_different_files_for_one_name_are_refused(self):
        other = self.path("other")
        self.library(other, "libgcc_s.so.1", needed=["libc.so.6"], verneed=[("libc.so.6", ["GLIBC_2.30"])])
        self.elf(os.path.join(self.llvm, "bin", "llvm-nm"), needed=["libgcc_s.so.1", "libLLVM.so.21.1", "libc.so.6"],
                 interpreter=INTERPRETER, runpath=other, verneed=[LIBC])
        with self.assertRaisesRegex(pe.EngineError, "lib/libgcc_s.so.1 collides"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_library_root_file_that_links_out_of_the_root_is_refused(self):
        root = self.overrideRoot()
        outside = self.library(self.path("outside"), "libedit.so.2.0.72", soname="libedit.so.2", needed=["libc.so.6"])
        link = os.path.join(root, "usr", "lib", "x86_64-linux-gnu", "libedit.so.2")
        os.remove(link)
        os.symlink(outside, link)
        with self.assertRaisesRegex(pe.EngineError, "leaves library root"):
            self.prepare(libraryDirs=[root])
        self.assertFalse(os.path.lexists(self.path("out")))

    def test_runpath_tokens_other_than_origin_and_relative_entries_are_refused(self):
        for runpath, text in (("$LIB/x", r"\$LIB"), ("lib", "relative"), ("$ORIGIN/../lib:${PLATFORM}", r"\$\{PLATFORM\}")):
            self.elf(os.path.join(self.llvm, "bin", "llvm-nm"), needed=["libgcc_s.so.1", "libc.so.6"], interpreter=INTERPRETER,
                     runpath=runpath, verneed=[LIBC])
            with self.assertRaisesRegex(pe.EngineError, text):
                self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_tool_that_is_not_an_elf_executable_with_the_system_loader_is_refused(self):
        write(os.path.join(self.llvm, "bin", "llvm-ar"), "#!/bin/sh\n", 0o755)
        with self.assertRaisesRegex(pe.EngineError, "llvm-ar: not an ELF"):
            self.prepare(libraryDirs=[self.overrideRoot()])
        self.elf(os.path.join(self.llvm, "bin", "llvm-ar"), needed=["libc.so.6"], verneed=[LIBC])
        with self.assertRaisesRegex(pe.EngineError, "llvm-ar: has no interpreter"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_foreign_machine_tool_is_refused(self):
        self.elf(os.path.join(self.llvm, "bin", "llvm-ar"), machine=183, interpreter=INTERPRETER)
        with self.assertRaisesRegex(pe.EngineError, "llvm-ar: machine 183"):
            self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_tool_is_planned_only_as_an_executable_or_position_independent_executable(self):
        tool = dict(needed=["libLLVM.so.21.1", "libc.so.6"], interpreter=INTERPRETER, runpath="$ORIGIN/../lib", verneed=[LIBC])
        for kind in (2, 3):
            self.elf(os.path.join(self.llvm, "bin", "llvm-ar"), type=kind, **tool)
            self.prepare(output=self.path("accepted", str(kind)), libraryDirs=[self.overrideRoot()])
        for kind, name in ((1, "ET_REL"), (4, "ET_CORE"), (5, "unknown"), (0xfe00, "unknown")):
            self.elf(os.path.join(self.llvm, "bin", "llvm-ar"), type=kind, **tool)
            with self.subTest(kind=kind):
                with self.assertRaisesRegex(pe.EngineError, r"llvm-ar: ELF type %d \(%s\) is not ET_EXEC or ET_DYN, required of bin/llvm-ar" % (kind, name)):
                    self.prepare(libraryDirs=[self.overrideRoot()])

    def test_a_planned_library_must_be_a_shared_object(self):
        for kind, name in ((1, "ET_REL"), (2, "ET_EXEC"), (4, "ET_CORE"), (0xfe00, "unknown")):
            self.library(self.hostLibs, "libgcc_s.so.1", type=kind, verneed=[("libc.so.6", ["GLIBC_2.35"])])
            with self.subTest(kind=kind):
                with self.assertRaisesRegex(pe.EngineError, r"libgcc_s\.so\.1: ELF type %d \(%s\) is not ET_DYN, required of lib/libgcc_s\.so\.1" % (kind, name)):
                    self.prepare(libraryDirs=[self.overrideRoot()])
        self.library(self.hostLibs, "libgcc_s.so.1", type=3, verneed=[("libc.so.6", ["GLIBC_2.35"])])
        self.prepare(libraryDirs=[self.overrideRoot()])

    def test_target_runtime_elf_files_in_the_resource_directory_are_carried_as_data(self):
        resource = os.path.join(self.llvm, "lib", "clang", "21", "lib", "linux")
        self.elf(os.path.join(resource, "libclang_rt.asan-i386.so"), elfClass=1, machine=3, needed=["libc.so.6"])
        self.elf(os.path.join(resource, "libclang_rt.asan-x86_64.so"), needed=["libpthread.so.0"], runpath="/host/lib")
        out, (_, _, count), plan, _ = self.prepare(libraryDirs=[self.overrideRoot()])
        self.assertTrue(os.path.isfile(os.path.join(out, "lib", "clang", "21", "lib", "linux", "libclang_rt.asan-i386.so")))
        self.assertEqual(count, len([n for n in plan if (n.startswith("bin/") or n.startswith("lib/")) and not n.startswith("lib/clang/")]))
        self.assertEqual(fields(os.path.join(out, "lib", "clang", "21", "lib", "linux", "libclang_rt.asan-x86_64.so"))["runpath"],
                         "/host/lib")


class PrepareTest(unittest.TestCase):
    def setUp(self):
        self.world = built()
        self.out, self.root, self.llvm, self.host = (getattr(self.world, n) for n in ("out", "root", "llvm", "host"))
        self.patchelf, self.sources, self.dir = self.world.patchelf, self.world.sources, self.world.dir
        _, self.verified, self.plan, self.records = self.world.result

    def calls(self):
        return self.world.calls()

    def tree(self, root):
        return self.world.tree(root)

    def info(self, rel):
        with mock.patch.object(pl, "inspect", side_effect=inProcess):
            return pl.readElf(os.path.join(self.out, rel), os.path.join(self.out, "bin", "llvm-readobj"))

    def test_the_bundle_has_the_engine_layout_the_linux_contract_and_the_drivers(self):
        listed = pe.listFiles(self.out)
        for rel in ("HOST", "VERSION", "bin/clang-21", "bin/lld", "bin/llvm-ar", "bin/dsymutil", "lib/libLLVM.so.21.1",
                    "lib/libedit.so.2", "lib/clang/21/include/stddef.h", "lib/clang/21/lib/linux/libclang_rt.builtins-x86_64.a",
                    "notices/provenance.json", "notices/libedit2/copyright"):
            self.assertIn(rel, listed)
        self.assertEqual(read(os.path.join(self.out, "HOST")), "x86_64-linux\n")
        self.assertEqual(read(os.path.join(self.out, "VERSION")), "21.1.8\n")
        for alias in ("clang", "clang++"):
            self.assertEqual(os.readlink(os.path.join(self.out, "bin", alias)), "clang-21")
        for alias in ("ld64.lld", "ld.lld", "lld-link", "wasm-ld"):
            self.assertEqual(os.readlink(os.path.join(self.out, "bin", alias)), "lld")
        with mock.patch.object(pl, "inspect", side_effect=inProcess), mock.patch.object(pl, "detectHost", return_value=pe.LINUX_X64):
            self.assertEqual(pe.verifyEngine(self.out), self.verified)
        self.assertEqual(self.verified[:2], ("x86_64-linux", "21.1.8"))

    def test_the_clang_executable_is_the_install_clang_under_the_versioned_name(self):
        self.assertEqual(self.plan["bin/clang-21"], os.path.join(self.llvm, "bin", "clang"))

    def test_every_engine_elf_carries_exactly_one_bundle_relative_runpath_or_none(self):
        expected = {"bin/clang-21": "$ORIGIN/../lib", "bin/lld": "$ORIGIN/../lib", "bin/dsymutil": "$ORIGIN/../lib",
                    "bin/llvm-readobj": "$ORIGIN/../lib",
                    "lib/libLLVM.so.21.1": "$ORIGIN", "lib/libclang-cpp.so.21.1": "$ORIGIN", "lib/libstdc++.so.6": "$ORIGIN",
                    "lib/libedit.so.2": "$ORIGIN", "lib/libtinfo.so.6": None, "lib/libgcc_s.so.1": None}
        for rel, runpath in expected.items():
            info = self.info(rel)
            self.assertEqual((rel, info["runpath"], info["rpath"]), (rel, runpath, None))

    def test_patchelf_removes_then_sets_only_on_objects_that_need_a_rewrite(self):
        calls = self.calls()
        self.assertEqual(calls[0], "--version")
        removed = [i for i, c in enumerate(calls) if c.startswith("--remove-rpath") and c.endswith("/lib/libclang-cpp.so.21.1")]
        self.assertEqual(len(removed), 1)
        self.assertRegex(calls[removed[0] + 1], r"^--set-rpath \$ORIGIN .*/lib/libclang-cpp\.so\.21\.1$")
        edit = [c for c in calls if c.endswith("/lib/libedit.so.2")]
        self.assertEqual([c.split()[0] for c in edit], ["--set-rpath"])
        for untouched in ("bin/clang-21", "bin/lld", "lib/libtinfo.so.6", "lib/libgcc_s.so.1"):
            self.assertEqual([c for c in calls if c.endswith("/" + untouched)], [], msg=untouched)
        for call in calls[1:]:
            self.assertIn(".partial-", call.split()[-1], msg=call)

    def test_no_source_path_survives_in_any_runpath(self):
        for rel in pe.listFiles(self.out):
            path = os.path.join(self.out, rel)
            info = None if os.path.islink(path) or "/clang/" in rel else self.info(rel)
            if info:
                for field in ("runpath", "rpath"):
                    self.assertFalse(info[field] and (self.dir in info[field] or info[field].startswith("/")), msg=(rel, info))

    def test_sources_and_override_roots_are_not_changed(self):
        self.assertEqual({"llvm": self.tree(self.llvm), "host": self.tree(self.host), "root": self.tree(self.root)}, self.sources)

    def test_the_receipt_states_local_proof_tools_baseline_and_every_library_source(self):
        receipt = json.loads(read(os.path.join(self.out, "notices", "provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual((receipt["host"], receipt["clangVersion"], receipt["lldVersion"], receipt["glibcBaseline"]),
                         ("x86_64-linux", "21.1.8", "21.1.8", "2.39"))
        self.assertEqual(receipt["patchelf"], {"version": "patchelf 0.18.0", "sha256": pe.sha256File(self.patchelf)})
        libraries = {f["path"]: f for f in receipt["files"] if f["path"].startswith("lib/") and not f["path"].startswith("lib/clang/")}
        self.assertEqual(sorted(libraries), ["lib/libLLVM.so.21.1", "lib/libclang-cpp.so.21.1", "lib/libedit.so.2",
                                             "lib/libgcc_s.so.1", "lib/libstdc++.so.6", "lib/libtinfo.so.6"])
        edit = libraries["lib/libedit.so.2"]
        source = os.path.join(self.root, "usr", "lib", "x86_64-linux-gnu", "libedit.so.2.0.72")
        self.assertEqual((edit["source"], edit["sourceSha256"], edit["origin"], edit["package"]),
                         (source, pe.sha256File(source), self.root, "libedit2"))
        self.assertEqual(libraries["lib/libtinfo.so.6"]["origin"], "host")
        self.assertEqual(libraries["lib/libtinfo.so.6"]["package"], "libtinfo6")
        self.assertEqual(receipt["files"][0]["path"], sorted(f["path"] for f in receipt["files"])[0])
        self.assertEqual([f["path"] for f in receipt["files"] if f["path"].startswith("bin/")][:2], ["bin/clang-21", "bin/dsymutil"])

    def test_the_inspector_is_a_bundled_tool_whose_source_and_hash_the_receipt_records(self):
        receipt = json.loads(read(os.path.join(self.out, "notices", "provenance.json")))
        record = next(f for f in receipt["files"] if f["path"] == "bin/llvm-readobj")
        self.assertEqual((record["source"], record["sourceSha256"], record["origin"], record["package"]),
                         (self.world.inspector, pe.sha256File(self.world.inspector), "host", "llvm-21"))
        self.assertEqual(receipt["inspector"], {"version": "21.1.8", "sha256": pe.sha256File(self.world.inspector)})
        self.assertEqual(self.plan["bin/llvm-readobj"], self.world.inspector)

    def test_preparing_reads_with_the_source_inspector_and_never_with_a_file_of_the_bundle(self):
        world = Builder()
        world.setUp()
        self.addCleanup(world.doCleanups)
        with mock.patch.object(pl, "inspect", side_effect=inProcess) as inspect:
            world.prepare(libraryDirs=[world.overrideRoot()])
        self.assertEqual({c.args[0] for c in inspect.call_args_list}, {world.inspector})

    def test_the_engine_major_of_every_prepared_runtime_caller_reads_a_linux_bundle_with_the_one_argument_it_passes(self):
        with mock.patch.object(pl, "inspect", side_effect=inProcess), mock.patch.object(pl, "detectHost", return_value=pe.LINUX_X64):
            self.assertEqual(pr.engineMajor(self.out), ("x86_64-linux", "21.1.8", "21"))
        foreign = pe.EngineError("unsupported host darwin: only native Linux x86_64 is implemented")
        with mock.patch.object(pl, "detectHost", side_effect=foreign), mock.patch.object(pl.subprocess, "run", side_effect=AssertionError("run")):
            with self.assertRaisesRegex(pe.EngineError, "pass --inspector"):
                pr.engineMajor(self.out)

    def test_every_package_that_supplied_a_file_has_a_notice_with_its_copyright_and_version(self):
        receipt = json.loads(read(os.path.join(self.out, "notices", "provenance.json")))
        names = sorted(p["name"] for p in receipt["packages"])
        self.assertEqual(names, ["libclang-common-21-dev", "libclang-cpp21", "libedit2", "libgcc-s1", "libllvm21",
                                 "libstdc++6", "libtinfo6", "llvm-21"])
        edit = next(p for p in receipt["packages"] if p["name"] == "libedit2")
        self.assertEqual(edit["version"], "3.1-20230828-1build1")
        self.assertEqual(edit["copyright"], "notices/libedit2/copyright")
        self.assertEqual(read(os.path.join(self.out, "notices", "libedit2", "copyright")), "copyright of libedit2 3.1-20230828-1build1\n")
        self.assertEqual(edit["source"], "extracted package " + self.root)
        host = next(p for p in receipt["packages"] if p["name"] == "libtinfo6")
        self.assertEqual((host["version"], host["source"]), ("libtinfo6-1", "host dpkg"))
        for package in receipt["packages"]:
            self.assertEqual(package["copyrightSha256"], pe.sha256File(os.path.join(self.out, package["copyright"])))

    def test_the_source_path_literal_scan_counts_elf_files_that_hold_a_source_root(self):
        copy = os.path.join(tempfile.mkdtemp(prefix="scan-", dir=self.dir), "engine")
        shutil.copytree(self.out, copy, symlinks=True)
        with open(os.path.join(copy, "bin", "clang-21"), "ab") as f:
            f.write(self.llvm.encode() + b"\0" + self.llvm.encode())
        self.assertEqual(pe.sourcePathLiterals(copy, [self.llvm], pl.isElf), {"bin/clang-21": 2})
        self.assertEqual(pe.sourcePathLiterals(copy, [self.llvm]), {})


class RefusalTest(World):
    def refused(self, pattern, **kwargs):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.prepare(libraryDirs=kwargs.pop("libraryDirs", None) or [self.overrideRoot()], **kwargs)
        parent = self.path("out")
        self.assertEqual(os.listdir(parent) if os.path.isdir(parent) else [], [])

    def test_a_missing_or_non_executable_patchelf_is_refused_before_any_copy(self):
        self.refused("--patchelf .* is not an executable file", patchelf=self.path("tools", "none"))
        write(self.path("tools", "plain"), "x")
        self.refused("--patchelf .* is not an executable file", patchelf=self.path("tools", "plain"))
        self.assertEqual(self.calls(), [])

    def test_a_missing_library_directory_or_one_without_package_control_is_refused(self):
        self.refused("--library-dir .* is not a directory", libraryDirs=[self.path("nope")])
        bare = self.path("bare")
        os.makedirs(os.path.join(bare, "usr", "lib", "x86_64-linux-gnu"))
        self.refused("bare: no DEBIAN/control", libraryDirs=[bare])

    def test_a_control_file_without_package_or_version_is_refused(self):
        root = self.overrideRoot()
        write(os.path.join(root, "DEBIAN", "control"), "Package: libedit2\n")
        self.refused("DEBIAN/control has no Version", libraryDirs=[root])

    def test_the_role_gate_names_a_host_provided_library_for_lib_only(self):
        shared = dict(type=3, soname="libc.so.6", interpreter=None)
        for name in sorted(pl.SYSTEM_LIBRARIES):
            self.assertEqual(pl.roleProblem("lib/" + name, dict(shared, soname=name)), "is a host-provided system library, never bundled")
        self.assertIsNone(pl.roleProblem("lib/libLLVM.so.21.1", dict(shared, soname="libLLVM.so.21.1")))
        self.assertIsNone(pl.roleProblem("lib/libstdc++.so.6", dict(shared, soname="libstdc++.so.6")))
        self.assertIsNone(pl.roleProblem("bin/libc.so.6", dict(shared, type=2, interpreter=pl.INTERPRETER)))

    def test_a_package_without_a_copyright_file_is_refused(self):
        root = self.overrideRoot()
        os.remove(os.path.join(root, "usr", "share", "doc", "libedit2", "copyright"))
        self.refused("libedit2: no copyright file", libraryDirs=[root])

    def test_a_package_control_or_copyright_that_links_out_of_the_root_is_refused_and_an_inside_link_is_not(self):
        outside = self.path("outside meta")
        write(outside, "Package: libedit2\nVersion: 9\n")
        for label, rel in (("control", ("DEBIAN", "control")), ("copyright", ("usr", "share", "doc", "libedit2", "copyright"))):
            root = self.overrideRoot()
            path = os.path.join(root, *rel)
            os.remove(path)
            os.symlink(outside, path)
            with self.subTest(label, link="outside"):
                with self.assertRaisesRegex(pe.EngineError, r"%s leaves package root" % label.replace(".", r"\.")) as caught:
                    pl.describeRoot(root)
                self.assertIn(root, str(caught.exception))
            os.remove(path)
            write(path + ".real", "Package: libedit2\nVersion: 3\n" if label == "control" else "copyright\n")
            os.symlink(os.path.basename(path) + ".real", path)
            with self.subTest(label, link="inside"):
                self.assertEqual(pl.describeRoot(root)["name"], "libedit2")

    def opened(self, call):
        """The real paths builtins.open was asked for while call ran, and call's exception or result."""
        import builtins
        real, seen = builtins.open, []

        def spy(path, *args, **kwargs):
            seen.append(os.path.realpath(path) if isinstance(path, (str, bytes, os.PathLike)) else path)
            return real(path, *args, **kwargs)

        with mock.patch.object(builtins, "open", side_effect=spy):
            try:
                return seen, call(), None
            except pe.EngineError as error:
                return seen, None, error

    def test_a_control_that_links_out_of_the_root_is_refused_before_it_is_opened_whatever_it_holds(self):
        for label, body in ("valid package", "Package: libedit2\nVersion: 9\n"), ("no package", "nothing here\n"), ("not utf-8", None):
            root = self.overrideRoot()
            outside = self.path("outside control %s" % label)
            if body is None:
                with open(outside, "wb") as f:
                    f.write(b"\xff\xfe\0")
            else:
                write(outside, body)
            control = os.path.join(root, "DEBIAN", "control")
            os.remove(control)
            os.symlink(outside, control)
            seen, result, error = self.opened(lambda: pl.describeRoot(root))
            with self.subTest(label):
                self.assertIsNone(result)
                self.assertRegex(str(error), r"DEBIAN/control leaves package root")
                self.assertIn(root, str(error))
                self.assertNotIn(os.path.realpath(outside), seen)

    def test_a_control_inside_the_root_is_opened_and_read_and_a_package_root_alias_is_not_a_leak(self):
        root = self.overrideRoot()
        os.symlink(root, self.path("alias edit-root"))
        for held in (root, self.path("alias edit-root")):
            seen, result, error = self.opened(lambda: pl.describeRoot(held))
            self.assertIsNone(error)
            self.assertEqual(result["name"], "libedit2")
            self.assertIn(os.path.realpath(os.path.join(root, "DEBIAN", "control")), seen)

    def test_a_package_root_reached_through_a_link_is_still_a_valid_root(self):
        root = self.overrideRoot()
        os.symlink(root, self.path("alias edit-root"))
        self.assertEqual(pl.describeRoot(self.path("alias edit-root"))["name"], "libedit2")

    def test_a_file_no_package_owns_is_refused(self):
        with mock.patch.object(pl, "hostPackageOwners", return_value={}):
            self.refused("no package owns")

    def test_clang_and_lld_of_different_versions_are_refused(self):
        self.versions["ld.lld"] = "21.1.7"
        self.refused("lld 21.1.7 does not match clang 21.1.8")

    def test_missing_roots_and_resource_directory_and_tools_are_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "--llvm-root .* is not a directory"):
            self.prepare(llvm=self.path("nope"), libraryDirs=[self.overrideRoot()])
        shutil.rmtree(os.path.join(self.llvm, "lib", "clang"))
        self.refused("missing resource directory")
        write(os.path.join(self.llvm, "lib", "clang", "21", "include", "stddef.h"))
        os.remove(os.path.join(self.llvm, "bin", "dsymutil"))
        self.refused("missing source file .*dsymutil")

    def test_a_symlink_in_the_resource_directory_is_refused(self):
        os.symlink("stddef.h", os.path.join(self.llvm, "lib", "clang", "21", "include", "alias.h"))
        self.refused("symlink in resource directory: alias.h")

    def test_an_existing_output_is_never_replaced_and_is_not_inside_a_source_or_library_root(self):
        root = self.overrideRoot()
        os.makedirs(self.path("out", "engine"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            self.prepare(libraryDirs=[root])
        for inside, text in ((os.path.join(self.llvm, "engine"), "source root"), (os.path.join(root, "engine"), "library")):
            with self.assertRaisesRegex(pe.EngineError, "must not be inside a (source root|library root)"):
                self.prepare(output=inside, libraryDirs=[root])
        os.symlink(self.llvm, self.path("alias"))
        with self.assertRaisesRegex(pe.EngineError, "must not be inside a source root"):
            self.prepare(output=self.path("alias", "engine"), libraryDirs=[root])

    def test_a_patchelf_failure_leaves_no_output_or_partial(self):
        with mock.patch.dict(os.environ, {"FAKE_PATCHELF_FAILS": "1"}):
            self.refused("patchelf.*failed", libraryDirs=[self.overrideRoot()])

    def test_a_patchelf_that_leaves_the_wrong_runpath_is_refused(self):
        write(self.patchelf, "#!%s\nimport sys\nif sys.argv[1:] == ['--version']:\n    print('patchelf 0.18.0')\n" % sys.executable, 0o755)
        self.refused("runpath is None, expected \\$ORIGIN")


class HostTest(unittest.TestCase):
    def test_only_native_linux_x86_64_is_supported(self):
        with mock.patch.object(pl.sys, "platform", "linux"), mock.patch.object(pl.platform, "machine", return_value="x86_64"):
            self.assertEqual(pl.detectHost(), pe.LINUX_X64)
        for platform_, machine in (("darwin", "x86_64"), ("linux", "aarch64"), ("win32", "AMD64")):
            with mock.patch.object(pl.sys, "platform", platform_), mock.patch.object(pl.platform, "machine", return_value=machine):
                with self.assertRaisesRegex(pe.EngineError, "unsupported host"):
                    pl.detectHost()


class VerifyTest(TempCase):
    def setUp(self):
        super().setUp()
        self.out = self.path("engine")
        shutil.copytree(built().out, self.out, symlinks=True)
        self.inspector = built().inspector
        for patcher in (mock.patch.object(pl, "inspect", side_effect=inProcess),
                        mock.patch.object(pl, "detectHost", return_value=pe.LINUX_X64)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def mutate(self, rel, **change):
        path = os.path.join(self.out, rel)
        mode = os.stat(path).st_mode
        info = fields(path)
        info.update(change)
        buildElf(path, **info)
        os.chmod(path, mode)
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")

    def refused(self, pattern):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            pe.verifyEngine(self.out)

    def inspectorsUsed(self, call):
        with mock.patch.object(pl, "inspect", side_effect=inProcess) as inspect:
            result = call()
        return result, {c.args[0] for c in inspect.call_args_list}

    def test_the_prepared_bundle_verifies_with_its_own_inspector_by_default(self):
        result, used = self.inspectorsUsed(lambda: pe.verifyEngine(self.out))
        self.assertEqual(result[:2], ("x86_64-linux", "21.1.8"))
        self.assertEqual(used, {os.path.join(self.out, "bin", "llvm-readobj")})
        self.assertEqual(pl.verifyEngine(self.out, pe.LINUX_X64, "21.1.8"), result[2])

    def test_an_explicit_inspector_replaces_the_bundled_one(self):
        result, used = self.inspectorsUsed(lambda: pe.verifyEngine(self.out, self.inspector))
        self.assertEqual((result[:2], used), (("x86_64-linux", "21.1.8"), {self.inspector}))

    def test_a_bundle_on_another_host_is_never_run_without_an_explicit_inspector(self):
        foreign = pe.EngineError("unsupported host darwin: only native Linux x86_64 is implemented")
        with mock.patch.object(pl, "detectHost", side_effect=foreign):
            with mock.patch.object(pl.subprocess, "run", side_effect=AssertionError("a foreign ELF was run")):
                with self.assertRaisesRegex(pe.EngineError, r"cannot run the bundle's own bin/llvm-readobj here \(unsupported host darwin.*\); pass --inspector"):
                    pe.verifyEngine(self.out)
            result, used = self.inspectorsUsed(lambda: pe.verifyEngine(self.out, self.inspector))
        self.assertEqual((result[0], used), ("x86_64-linux", {self.inspector}))

    def test_the_bundled_inspector_must_be_a_listed_regular_file_and_never_a_link(self):
        os.remove(os.path.join(self.out, "bin", "llvm-readobj"))
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        self.refused("layout: missing bin/llvm-readobj")
        os.symlink("llvm-ar", os.path.join(self.out, "bin", "llvm-readobj"))
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        self.refused("bin/llvm-readobj is a symlink")

    def test_a_bundled_inspector_that_fails_stops_the_verification_without_a_fallback(self):
        canned(os.path.join(self.out, "bin", "llvm-readobj"), code=1, stderr="loader: cannot open libLLVM.so.21.1\n")
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        with mock.patch.object(pl, "inspect", wraps=REAL_INSPECT):
            self.refused(r"llvm-readobj failed \(1\): loader: cannot open libLLVM\.so\.21\.1")

    def test_an_explicit_inspector_that_is_not_an_executable_file_is_refused(self):
        for inspector in (self.path("none"), self.path("tools")):
            with self.subTest(inspector=inspector):
                with self.assertRaisesRegex(pe.EngineError, "--inspector .* is not an executable file"):
                    pe.verifyEngine(self.out, inspector)

    def test_the_bundled_inspector_is_audited_like_every_other_engine_elf(self):
        self.mutate("bin/llvm-readobj", runpath="/usr/lib/llvm-21/lib")
        self.refused(r"bin/llvm-readobj: runpath is /usr/lib/llvm-21/lib, expected \$ORIGIN/\.\./lib")
        self.mutate("bin/llvm-readobj", runpath="$ORIGIN/../lib", verneed=[("libc.so.6", ["GLIBC_2.40"])])
        self.refused("bin/llvm-readobj: .*above the 2.39 baseline")

    def test_an_inspector_that_reads_a_file_differently_from_the_bundle_fails_the_verification(self):
        canned(self.path("tools", "fails"), code=1, stderr="inspector: cannot read\n")
        with self.assertRaisesRegex(pe.EngineError, r"fails failed \(1\): inspector: cannot read"):
            pe.verifyEngine(self.out, self.path("tools", "fails"))

    def test_a_dependency_with_an_unreadable_version_section_fails_the_verification(self):
        canned(self.path("tools", "bad"), jsonText=json.dumps([document()]), gnuText="stray\n")
        with self.assertRaisesRegex(pe.EngineError, "unrecognized version-info line"):
            pe.verifyEngine(self.out, self.path("tools", "bad"))

    def test_a_host_runpath_or_a_legacy_rpath_is_refused(self):
        self.mutate("bin/lld", runpath="/usr/lib/llvm-21/lib")
        self.refused(r"bin/lld: runpath is /usr/lib/llvm-21/lib, expected \$ORIGIN/\.\./lib")
        self.mutate("bin/lld", runpath="$ORIGIN/../lib", rpath="/host/lib")
        self.refused("bin/lld: has DT_RPATH /host/lib")

    def test_a_runpath_on_an_object_with_only_system_needs_is_refused(self):
        self.mutate("lib/libtinfo.so.6", runpath="$ORIGIN")
        self.refused("lib/libtinfo.so.6: runpath is \\$ORIGIN, expected none")

    def test_a_missing_runpath_on_an_object_with_bundled_needs_is_refused(self):
        self.mutate("lib/libedit.so.2", runpath=None)
        self.refused("lib/libedit.so.2: runpath is None, expected \\$ORIGIN")

    def test_a_needed_library_absent_from_the_bundle_is_refused(self):
        os.remove(os.path.join(self.out, "lib", "libgcc_s.so.1"))
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        self.refused("lib/libstdc\\+\\+.so.6: needs libgcc_s.so.1, which is not in lib/")

    def test_a_needed_name_with_a_path_is_refused(self):
        self.mutate("lib/libedit.so.2", needed=["/usr/lib/libtinfo.so.6", "libc.so.6"])
        self.refused("lib/libedit.so.2: needs /usr/lib/libtinfo.so.6 by a path")

    def test_a_bundled_library_whose_soname_differs_from_its_file_name_is_refused(self):
        self.mutate("lib/libtinfo.so.6", soname="libtinfo.so.5")
        self.refused("lib/libtinfo.so.6: soname is libtinfo.so.5")

    def test_a_version_the_bundled_provider_does_not_define_is_refused(self):
        self.mutate("lib/libtinfo.so.6", verdef=["NCURSES6_TINFO_6.0"])
        self.refused("lib/libedit.so.2: needs NCURSES6_TINFO_5.0.19991023 of libtinfo.so.6, which the bundled file does not define")

    def test_a_bundled_tool_must_be_an_executable_or_position_independent_executable(self):
        for kind in (2, 3):
            self.mutate("bin/llvm-nm", type=kind)
            self.assertEqual(pe.verifyEngine(self.out)[:2], ("x86_64-linux", "21.1.8"))
        for kind, name in ((1, "ET_REL"), (4, "ET_CORE"), (5, "unknown"), (0xfe00, "unknown")):
            self.mutate("bin/llvm-nm", type=kind)
            with self.subTest(kind=kind):
                self.refused(r"bin/llvm-nm: ELF type %d \(%s\) is not ET_EXEC or ET_DYN, required of bin/llvm-nm" % (kind, name))

    def test_a_bundled_library_must_be_a_shared_object(self):
        self.mutate("lib/libtinfo.so.6", type=3)
        self.assertEqual(pe.verifyEngine(self.out)[:2], ("x86_64-linux", "21.1.8"))
        for kind, name in ((1, "ET_REL"), (2, "ET_EXEC"), (4, "ET_CORE"), (0xfe00, "unknown")):
            self.mutate("lib/libtinfo.so.6", type=kind)
            with self.subTest(kind=kind):
                self.refused(r"lib/libtinfo\.so\.6: ELF type %d \(%s\) is not ET_DYN, required of lib/libtinfo\.so\.6" % (kind, name))

    def test_a_glibc_version_above_the_baseline_or_a_foreign_machine_is_refused(self):
        self.mutate("lib/libtinfo.so.6", verneed=[("libc.so.6", ["GLIBC_2.40"])])
        self.refused("lib/libtinfo.so.6: .*above the 2.39 baseline")
        self.mutate("lib/libtinfo.so.6", verneed=[LIBC], machine=183)
        self.refused("lib/libtinfo.so.6: machine 183")

    def test_a_tool_without_the_system_interpreter_or_that_is_not_elf_is_refused(self):
        self.mutate("bin/llvm-nm", interpreter=None)
        self.refused("bin/llvm-nm: has no interpreter")
        write(os.path.join(self.out, "bin", "llvm-ar"), "#!/bin/sh\n", 0o755)
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        self.refused("bin/llvm-ar: not an ELF")

    def test_a_bundled_host_provided_system_library_is_refused_even_when_it_is_otherwise_a_valid_shared_object(self):
        for name in sorted(pl.SYSTEM_LIBRARIES):
            path = os.path.join(self.out, "lib", name)
            buildElf(path, type=3, soname=name)
            os.chmod(path, 0o644)
            pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
            with self.subTest(name):
                self.refused(r"lib/%s: is a host-provided system library, never bundled" % name.replace(".", r"\."))
            os.remove(path)

    def test_a_missing_layout_file_is_refused(self):
        os.remove(os.path.join(self.out, "lib", "clang", "21", "lib", "linux", "libclang_rt.builtins-x86_64.a"))
        pe.writeContract(self.out, pe.LINUX_X64, "21.1.8")
        self.refused("layout: missing lib/clang/21/lib/linux/libclang_rt.builtins-x86_64.a")


class CommandLineTest(World):
    def test_the_command_line_prepares_and_then_verifies_a_bundle(self):
        root = self.overrideRoot()
        out = self.path("cli", "engine")
        argv = ["--llvm-root", self.llvm, "--lld-root", self.llvm, "--output", out, "--patchelf", self.patchelf,
                "--library-dir", root]
        self.assertEqual(pl.main(argv), 0)
        self.assertEqual(pl.main(["--verify", out]), 0)
        self.assertEqual(pl.main(["--verify", out, "--inspector", self.inspector]), 0)
        self.assertEqual(pl.main(argv), 1)
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            pl.main(["--llvm-root", self.llvm, "--output", self.path("cli", "x")])

    def test_verify_names_a_bundle_of_another_host_instead_of_labelling_it(self):
        mac = self.path("mac")
        write(os.path.join(mac, "bin", "tool"), "tool\n")
        pe.writeContract(mac, "aarch64-macos", "22.1.1")
        with mock.patch("sys.stderr", new_callable=__import__("io").StringIO) as err, \
                mock.patch.object(pe, "verifyEngine", side_effect=AssertionError("mach-o audit")):
            self.assertEqual(pl.main(["--verify", mac, "--inspector", self.inspector]), 1)
        self.assertIn("is a aarch64-macos bundle, not x86_64-linux", err.getvalue())

    def test_verify_of_a_linux_bundle_through_the_common_command_labels_it_elf(self):
        root = self.overrideRoot()
        out = self.path("cli2", "engine")
        self.assertEqual(pl.main(["--llvm-root", self.llvm, "--lld-root", self.llvm, "--output", out, "--patchelf", self.patchelf,
                                  "--library-dir", root]), 0)
        with mock.patch("sys.stdout", new_callable=__import__("io").StringIO) as printed:
            self.assertEqual(pe.main(["--verify", out]), 0)
        self.assertRegex(printed.getvalue(), r"^verified host=x86_64-linux version=21\.1\.8 elf=\d+\n$")


if __name__ == "__main__":
    unittest.main()
