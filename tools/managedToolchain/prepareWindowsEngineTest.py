import io
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsEngine as pw

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures", "windowsReadobj.txt")
FIXTURE_SHA256 = "d1f5d9817b12aef7b41d6a3a296516d01cc1605aed01c80b156f7eae7aa54128"
MARK = b"\n#FIELDS\n"
DEFAULTS = dict(machine=0x8664, magic=0x20B, characteristics=0x22, dllCharacteristics=0x8160, imports=[], delayImports=[])
DLL = 0x2022


def buildPe(path, mode=0o755, **given):
    """A file that starts as a PE image and carries its facts after a marker, for the fake inspector to print."""
    fields = dict(DEFAULTS, **given)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(b"MZ" + b"\0" * 30 + MARK + json.dumps(fields).encode())
    os.chmod(path, mode)
    return path


def fieldsOf(path):
    with open(path, "rb") as f:
        data = f.read()
    return json.loads(data[data.index(MARK) + len(MARK):])


def inspection(fields):
    lines = ["", "File: fake.exe", "Format: COFF-x86-64", "Arch: x86_64", "AddressSize: 64bit",
             "ImageFileHeader {", "  Machine: IMAGE_FILE_MACHINE_AMD64 (0x%X)" % fields["machine"], "  SectionCount: 9",
             "  Characteristics [ (0x%X)" % fields["characteristics"], "    IMAGE_FILE_EXECUTABLE_IMAGE (0x2)", "  ]", "}",
             "ImageOptionalHeader {", "  Magic: 0x%X" % fields["magic"],
             "  Characteristics [ (0x%X)" % fields["dllCharacteristics"], "    IMAGE_DLL_CHARACTERISTICS_NX_COMPAT (0x100)", "  ]", "}",
             "DOSHeader {", "  Magic: MZ", "}"]
    for name in fields["imports"]:
        lines += ["Import {", "  Name: %s" % name, "  ImportLookupTableRVA: 0x1", "  Symbol: Entry (0)", "}"]
    for name in fields["delayImports"]:
        lines += ["DelayImport {", "  Name: %s" % name, "  Attributes: 0x1", "  Import {", "    Address: 0x1", "  }", "}"]
    return "\n".join(lines) + "\n"


REAL_INSPECT = pw.inspect


def inProcess(inspector, flags, path):
    """pw.inspect for a fake inspector file, which cannot be spawned; any other inspector runs for real."""
    with open(inspector, "rb") as f:
        fake = MARK in f.read()
    if not fake:
        return REAL_INSPECT(inspector, flags, path)
    assert tuple(flags) == pw.INSPECT_FLAGS, flags
    return inspection(fieldsOf(path))


def reparse(*paths):
    """os.lstat as NTFS reports a junction: the reparse-point attribute on the named paths, whatever islink says."""
    real = os.lstat

    class Reparsed:
        st_file_attributes = stat.FILE_ATTRIBUTE_REPARSE_POINT

        def __init__(self, inner):
            self.inner = inner

        def __getattr__(self, name):
            return getattr(self.inner, name)

    def lstat(path, *args, **kwargs):
        found = real(path, *args, **kwargs)
        return Reparsed(found) if os.fspath(path) in paths else found

    return mock.patch.object(os, "lstat", side_effect=lstat)


def write(path, text="x\n", mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def read(path):
    with open(path) as f:
        return f.read()


def inspectorRun(stdout="", code=0, stderr=""):
    """subprocess.run as the inspector call sees it: the given exit status and text, nothing spawned."""
    return mock.patch.object(pw.subprocess, "run", return_value=subprocess.CompletedProcess(["llvm-readobj.exe"], code, stdout, stderr))


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareWindowsEngineTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def tree(self, root):
        return {os.path.relpath(os.path.join(d, n), root): (os.readlink(os.path.join(d, n)) if os.path.islink(os.path.join(d, n))
                                                            else pe.sha256File(os.path.join(d, n)))
                for d, _, names in os.walk(root) for n in names}


class ReaderTest(TempCase):
    def setUp(self):
        super().setUp()
        self.inspector = buildPe(self.path("tools", "llvm-readobj.exe"))
        patcher = mock.patch.object(pw, "inspect", side_effect=inProcess)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_the_facts_reach_the_dict_that_closure_and_verification_read(self):
        path = buildPe(self.path("a.exe"), imports=["KERNEL32.dll", "libA.dll"], delayImports=["ole32.dll"], characteristics=0x2022,
                       machine=0x14C, magic=0x10B)
        self.assertEqual(pw.readPe(path, self.inspector), {
            "machine": 0x14C, "magic": 0x10B, "characteristics": 0x2022, "imports": ["KERNEL32.dll", "libA.dll"],
            "delayImports": ["ole32.dll"]})

    def test_a_file_that_is_not_a_pe_image_reads_as_none_without_running_the_inspector(self):
        write(self.path("script"), "text, not a PE image\n")
        write(self.path("empty"), "")
        with mock.patch.object(pw.subprocess, "run", side_effect=AssertionError("inspector run")):
            self.assertIsNone(pw.readPe(self.path("script"), self.inspector))
            self.assertIsNone(pw.readPe(self.path("empty"), self.inspector))

    def test_a_system_name_in_any_case_and_a_nested_import_without_a_name_are_read_as_imports_of_the_top_level_block_only(self):
        path = buildPe(self.path("a.exe"), imports=["kernel32.DLL"], delayImports=["SHELL32.dll", "ole32.dll"])
        info = pw.readPe(path, self.inspector)
        self.assertEqual((info["imports"], info["delayImports"]), (["kernel32.DLL"], ["SHELL32.dll", "ole32.dll"]))


class ProtocolTest(TempCase):
    """readPe and inspect against the standard subprocess.run result: argv, exit status, stderr and stdout text."""
    def setUp(self):
        super().setUp()
        self.path_ = buildPe(self.path("a.exe"))

    def test_the_inspector_is_run_with_exactly_the_file_header_and_coff_import_flags(self):
        with inspectorRun("") as run:
            with self.assertRaises(pe.EngineError):
                pw.readPe(self.path_, "llvm-readobj.exe")
        self.assertEqual(run.call_args.args[0], ["llvm-readobj.exe", "--file-headers", "--coff-imports", self.path_])
        self.assertEqual(run.call_args.kwargs["stdout"], subprocess.PIPE)
        self.assertEqual(run.call_args.kwargs["stderr"], subprocess.PIPE)

    def test_an_inspector_that_fails_or_warns_is_an_error_naming_the_file(self):
        with inspectorRun(code=3, stderr="boom\n"):
            with self.assertRaisesRegex(pe.EngineError, r"a\.exe: llvm-readobj\.exe failed \(3\): boom"):
                pw.readPe(self.path_, "llvm-readobj.exe")
        with inspectorRun(inspection(DEFAULTS), stderr="warning: truncated import table\n"):
            with self.assertRaisesRegex(pe.EngineError, r"a\.exe: llvm-readobj\.exe warned: warning: truncated import table"):
                pw.readPe(self.path_, "llvm-readobj.exe")
        with inspectorRun(inspection(DEFAULTS), code=1):
            with self.assertRaisesRegex(pe.EngineError, r"failed \(1\)"):
                pw.readPe(self.path_, "llvm-readobj.exe")

    def test_a_clean_run_with_a_recorded_text_is_read_and_whitespace_only_stderr_is_not_a_warning(self):
        with inspectorRun(inspection(dict(DEFAULTS, imports=["KERNEL32.dll"])), stderr=" \n"):
            self.assertEqual(pw.readPe(self.path_, "llvm-readobj.exe")["imports"], ["KERNEL32.dll"])

    def test_a_header_or_import_the_inspector_leaves_out_or_repeats_is_refused_naming_it(self):
        path, good = self.path_, inspection(dict(DEFAULTS, imports=["KERNEL32.dll"]))
        cases = (
            ("no file header", good.replace("ImageFileHeader {", "Other {"), "0 ImageFileHeader blocks, not one"),
            ("two file headers", good + "ImageFileHeader {\n  Machine: X (0x8664)\n}\n", "2 ImageFileHeader blocks, not one"),
            ("no optional header", good.replace("ImageOptionalHeader {", "Other {"), "0 ImageOptionalHeader blocks, not one"),
            ("no machine", good.replace("  Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)\n", ""), "0 ImageFileHeader Machine lines, not one"),
            ("two machines", good.replace("  SectionCount: 9", "  Machine: IMAGE_FILE_MACHINE_AMD64 (0x8664)"), "2 ImageFileHeader Machine lines"),
            ("no characteristics", good.replace("  Characteristics [ (0x22)\n", "", 1), "0 ImageFileHeader Characteristics lines"),
            ("no magic", good.replace("  Magic: 0x20B\n", ""), "0 ImageOptionalHeader Magic lines"),
            ("import without a name", good.replace("  Name: KERNEL32.dll\n", ""), "Import block has no Name line first"),
            ("delay import without a name", good + "DelayImport {\n  Attributes: 0x1\n}\n", "DelayImport block has no Name line first"),
            ("empty import block", good + "Import {\n}\n", "Import block has no Name line first"),
            ("block that never ends", good + "Import {\n  Name: x.dll\n", "ends inside block Import"),
            ("block inside a block", good.replace("}\nImageOptionalHeader {", "ImageOptionalHeader {"), "starts inside block ImageFileHeader"),
            ("no output at all", "", "0 ImageFileHeader blocks, not one"))
        for label, text, pattern in cases:
            with self.subTest(label), inspectorRun(text):
                with self.assertRaisesRegex(pe.EngineError, pattern):
                    pw.readPe(path, "llvm-readobj.exe")


class RoleTest(unittest.TestCase):
    def info(self, **over):
        return dict(machine=0x8664, magic=0x20B, characteristics=0x22, imports=[], delayImports=[], **over)

    def test_an_amd64_pe32_plus_executable_is_an_exe_and_a_dll_image_is_a_dll(self):
        self.assertIsNone(pw.roleProblem("bin/clang.exe", self.info()))
        self.assertIsNone(pw.roleProblem("bin/CLANG.EXE", self.info()))
        self.assertIsNone(pw.roleProblem("bin/libfoo.dll", dict(self.info(), characteristics=DLL)))
        self.assertIsNone(pw.roleProblem("bin/LIBFOO.DLL", dict(self.info(), characteristics=DLL)))

    def test_another_machine_or_a_32_bit_image_or_a_non_executable_image_is_refused(self):
        for over, text in (({"machine": 0x14C}, "machine 0x14c, not AMD64 (0x8664)"), ({"machine": 0xAA64}, "machine 0xaa64"),
                           ({"machine": 0}, "machine 0x0"), ({"magic": 0x10B}, "optional header magic 0x10b, not PE32+ (0x20b)"),
                           ({"magic": 0x107}, "magic 0x107"), ({"characteristics": 0x2000}, "is not an executable image (characteristics 0x2000)"),
                           ({"characteristics": 0}, "is not an executable image")):
            with self.subTest(over):
                self.assertIn(text, pw.roleProblem("bin/x.exe", dict(self.info(), **over)))

    def test_an_exe_that_is_a_dll_and_a_dll_that_is_not_are_refused_naming_the_file(self):
        self.assertEqual(pw.roleProblem("bin/x.exe", dict(self.info(), characteristics=DLL)),
                         "is a DLL image, required to be an executable of bin/x.exe")
        self.assertEqual(pw.roleProblem("bin/x.dll", self.info()), "is an executable image, required to be a DLL of bin/x.dll")

    def test_the_system_allowlist_and_the_tools_are_exactly_the_observed_ones(self):
        self.assertEqual(sorted(pw.SYSTEM_DLLS), ["advapi32.dll", "kernel32.dll", "ntdll.dll", "ole32.dll", "oleaut32.dll",
                                                  "shell32.dll", "user32.dll", "version.dll"])
        self.assertEqual(len(pw.TOOLS), 12)
        for name in ("dsymutil.exe", "clang-22.exe", "ld64.lld.exe"):
            self.assertNotIn(name, pw.TOOLS)


class RecordedReaderTest(TempCase):
    """readPe on a verbatim excerpt of complete blocks of one recorded llvm-readobj run on llvm-readobj.exe of the LLVM
    22.1.1 Windows payload: the file header, the optional header, the ntdll.dll import and the ole32.dll delay import."""
    def setUp(self):
        super().setUp()
        with open(FIXTURE, encoding="utf-8", newline="") as f:
            self.text = f.read()
        self.exe = buildPe(self.path("llvm-readobj.exe"))

    def test_the_fixture_is_the_pinned_excerpt_and_holds_no_private_path_or_prologue(self):
        self.assertEqual(pe.sha256File(FIXTURE), FIXTURE_SHA256)
        self.assertEqual(self.text.count("\n"), 106)
        for private in ("/Users", "File:", "Format:", "DOSHeader"):
            self.assertNotIn(private, self.text)

    def test_the_fixture_holds_complete_top_level_blocks_and_the_delay_import_nests_its_own_import_block(self):
        blocks = pw.readBlocks("fixture", self.text)
        self.assertEqual([name for name, _ in blocks], ["ImageFileHeader", "ImageOptionalHeader", "Import", "DelayImport"])
        self.assertIn("  Import {", dict(blocks)["DelayImport"])
        self.assertEqual(pw.readImports("fixture", blocks), {"Import": ["ntdll.dll"], "DelayImport": ["ole32.dll"]})

    def test_the_recorded_text_reads_as_an_amd64_pe32_plus_executable_with_a_normal_and_a_delayed_import(self):
        with inspectorRun(self.text) as run:
            info = pw.readPe(self.exe, "llvm-readobj.exe")
        self.assertEqual(run.call_args.args[0], ["llvm-readobj.exe", "--file-headers", "--coff-imports", self.exe])
        self.assertEqual(info, {"machine": 0x8664, "magic": 0x20B, "characteristics": 0x22, "imports": ["ntdll.dll"],
                                "delayImports": ["ole32.dll"]})
        self.assertIsNone(pw.roleProblem("bin/llvm-readobj.exe", info))
        self.assertEqual({n.casefold() for n in pw.importedNames(info)} - pw.SYSTEM_DLLS, set())

    def test_the_recorded_text_as_a_dll_or_for_another_machine_is_refused_by_the_role_gate(self):
        for old, new, pattern in (("(0x22)", "(0x2022)", "is a DLL image"), ("(0x8664)", "(0xAA64)", "machine 0xaa64"),
                                  ("Magic: 0x20B", "Magic: 0x10B", "not PE32\\+")):
            self.assertEqual(self.text.count(old), 1, old)
            with self.subTest(old), inspectorRun(self.text.replace(old, new)):
                info = pw.readPe(self.exe, "llvm-readobj.exe")
                self.assertRegex(pw.roleProblem("bin/llvm-readobj.exe", info), pattern)

    def test_each_recorded_block_is_required_by_the_reader(self):
        blocks = pw.readBlocks("fixture", self.text)
        for dropped, pattern in (("ImageFileHeader", "0 ImageFileHeader blocks"), ("ImageOptionalHeader", "0 ImageOptionalHeader blocks")):
            kept = "".join("%s {\n%s\n}\n" % (n, "\n".join(l)) for n, l in blocks if n != dropped)
            with self.subTest(dropped), inspectorRun(kept):
                with self.assertRaisesRegex(pe.EngineError, pattern):
                    pw.readPe(self.exe, "llvm-readobj.exe")
        without = "".join("%s {\n%s\n}\n" % (n, "\n".join(l)) for n, l in blocks if n not in ("Import", "DelayImport"))
        with inspectorRun(without):
            self.assertEqual(pw.readPe(self.exe, "llvm-readobj.exe")["imports"], [])

    def test_the_recorded_text_cut_inside_a_block_is_refused(self):
        with inspectorRun(self.text[:self.text.index("DelayImport {") + len("DelayImport {\n  Name: ole32.dll\n")]):
            with self.assertRaisesRegex(pe.EngineError, "ends inside block DelayImport"):
                pw.readPe(self.exe, "llvm-readobj.exe")


MISSING = object()


class World(TempCase):
    """A fake installed LLVM: twelve fake PE tools in bin/, a resource directory, an operator license."""
    def setUp(self):
        super().setUp()
        self.llvm = self.path("LLVM root")
        self.bin = os.path.join(self.llvm, "bin")
        for tool in pw.TOOLS:
            buildPe(os.path.join(self.bin, tool), imports=["KERNEL32.dll", "ntdll.dll"], delayImports=["ole32.dll"])
        shutil.copyfile(os.path.join(self.bin, "clang.exe"), os.path.join(self.bin, "clang++.exe"))
        write(os.path.join(self.llvm, "lib", "clang", "22", "include", "stddef.h"), "stddef\n")
        write(os.path.join(self.llvm, "lib", "clang", "22", "lib", "windows", "clang_rt.builtins-x86_64.lib"), "!<arch>\n")
        self.license = self.path("licenses", "LLVM license.txt")
        write(self.license, "Apache-2.0 WITH LLVM-exception\n")
        self.versions = {"clang.exe": "22.1.1", "ld.lld.exe": "22.1.1", "llvm-readobj.exe": "22.1.1"}
        self.inspector = os.path.join(self.bin, "llvm-readobj.exe")
        self.patchers = (mock.patch.object(pw, "detectHost", return_value=pe.WINDOWS_X64),
                         mock.patch.object(pe, "toolVersion", side_effect=lambda binary, pattern: self.versions[os.path.basename(binary)]),
                         mock.patch.object(pw, "inspect", side_effect=inProcess))
        self.detect, self.version, self.inspect = (p.start() for p in self.patchers)
        for patcher in self.patchers:
            self.addCleanup(patcher.stop)

    def dll(self, name, **fields):
        fields.setdefault("characteristics", DLL)
        return buildPe(os.path.join(self.bin, name), **fields)

    def importing(self, *imports, delay=(), tool="llvm-nm.exe"):
        buildPe(os.path.join(self.bin, tool), imports=list(imports), delayImports=list(delay))

    def prepare(self, output=None, license=MISSING):
        return pw.prepareEngine(self.llvm, self.license if license is MISSING else license, output or self.path("out", "engine"))

    def refused(self, pattern, **kwargs):
        before = self.tree(self.llvm)
        with self.assertRaisesRegex(pe.EngineError, pattern):
            self.prepare(**kwargs)
        parent = self.path("out")
        self.assertEqual(os.listdir(parent) if os.path.isdir(parent) else [], [])
        self.assertEqual(self.tree(self.llvm), before)


class PrepareTest(World):
    def test_the_bundle_has_the_engine_layout_the_windows_contract_and_the_real_tool_files(self):
        out, (host, version, count), plan, _ = self.prepare()
        listed = pe.listFiles(out)
        for tool in pw.TOOLS:
            self.assertIn("bin/" + tool, listed)
        for rel in ("HOST", "VERSION", "lib/clang/22/include/stddef.h", "lib/clang/22/lib/windows/clang_rt.builtins-x86_64.lib",
                    "notices/provenance.json", "notices/LICENSE.TXT"):
            self.assertIn(rel, listed)
        self.assertEqual((host, version, count), (pe.WINDOWS_X64, "22.1.1", 12))
        self.assertEqual(read(os.path.join(out, "HOST")), "x86_64-windows\n")
        self.assertEqual(read(os.path.join(out, "VERSION")), "22.1.1\n")
        self.assertEqual([n for n in listed if n.startswith("bin/") and n[4:] not in pw.TOOLS], [])
        for name in ("bin/dsymutil.exe", "bin/clang-22.exe", "bin/ld64.lld.exe"):
            self.assertNotIn(name, listed)
        self.assertEqual(pe.verifyEngine(out), (pe.WINDOWS_X64, "22.1.1", 12))
        self.assertEqual(plan["bin/clang.exe"], os.path.join(self.bin, "clang.exe"))

    def test_aliases_are_real_files_with_the_bytes_of_their_source_and_no_symlink_is_made(self):
        out, *_ = self.prepare()
        for tool in pw.TOOLS:
            copy = os.path.join(out, "bin", tool)
            self.assertFalse(os.path.islink(copy))
            self.assertEqual(pe.sha256File(copy), pe.sha256File(os.path.join(self.bin, tool)))
        self.assertEqual(pe.sha256File(os.path.join(out, "bin", "clang++.exe")), pe.sha256File(os.path.join(out, "bin", "clang.exe")))
        self.assertEqual([n for d, ds, fs in os.walk(out) for n in ds + fs if os.path.islink(os.path.join(d, n))], [])

    def test_the_source_is_not_changed_and_the_license_is_copied_byte_for_byte(self):
        before = self.tree(self.llvm)
        out, *_ = self.prepare()
        self.assertEqual(self.tree(self.llvm), before)
        self.assertEqual(read(os.path.join(out, "notices", "LICENSE.TXT")), read(self.license))

    def test_a_dll_of_the_source_bin_is_copied_under_its_own_name_and_its_own_imports_are_followed(self):
        self.importing("LIBFOO.dll", "kernel32.DLL", delay=["libbar.dll", "SHELL32.dll"])
        self.dll("LibFoo.dll", imports=["KERNEL32.dll", "libbaz.dll"])
        self.dll("libbar.dll", imports=["ntdll.dll"])
        self.dll("libbaz.DLL", delayImports=["USER32.dll"])
        out, _, plan, _ = self.prepare()
        listed = pe.listFiles(out)
        for name in ("LibFoo.dll", "libbar.dll", "libbaz.DLL"):
            self.assertIn("bin/" + name, listed)
            self.assertEqual(pe.sha256File(os.path.join(out, "bin", name)), pe.sha256File(os.path.join(self.bin, name)))
        self.assertEqual([n for n in listed if n.startswith("bin/") and n[4:] not in pw.TOOLS], ["bin/LibFoo.dll", "bin/libbar.dll", "bin/libbaz.DLL"])
        self.assertEqual(pe.verifyEngine(out)[2], 15)

    def test_a_dll_two_tools_need_is_copied_once(self):
        self.importing("libfoo.dll", tool="llvm-nm.exe")
        self.importing("LIBFOO.DLL", tool="llvm-ar.exe")
        self.dll("libfoo.dll")
        out, _, plan, _ = self.prepare()
        self.assertEqual([n for n in plan if n.lower().endswith("libfoo.dll")], ["bin/libfoo.dll"])

    def test_the_receipt_states_local_proof_with_the_license_inspector_allowlist_and_every_source_hash(self):
        out, _, plan, record = self.prepare()
        receipt = json.loads(read(os.path.join(out, "notices", "provenance.json")))
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual((receipt["host"], receipt["clangVersion"], receipt["lldVersion"]), (pe.WINDOWS_X64, "22.1.1", "22.1.1"))
        self.assertEqual(receipt["inspector"], {"version": "22.1.1", "sha256": pe.sha256File(self.inspector)})
        self.assertEqual(receipt["systemDlls"], sorted(pw.SYSTEM_DLLS))
        self.assertEqual(receipt["license"], {"source": self.license, "sha256": pe.sha256File(self.license), "bytes": len(read(self.license)),
                                              "copy": "notices/LICENSE.TXT", "statement": "supplied by the operator and not checked against the release"})
        self.assertEqual(record, receipt["license"])
        files = {f["path"]: f for f in receipt["files"]}
        self.assertEqual(sorted(files), ["bin/" + t for t in sorted(pw.TOOLS)])
        for path, entry in files.items():
            self.assertEqual((entry["source"], entry["sourceSha256"]), (plan[path], pe.sha256File(plan[path])))
            self.assertEqual(entry["imports"], ["KERNEL32.dll", "ntdll.dll", "ole32.dll"])
        self.assertNotIn("certif", json.dumps(receipt).replace("redistributionCertified", "").lower())

    def test_an_explicit_root_reached_through_a_link_is_a_valid_root(self):
        os.symlink(self.llvm, self.path("alias root"))
        out, (_, _, count), plan, _ = pw.prepareEngine(self.path("alias root"), self.license, self.path("out2", "engine"))
        self.assertEqual(count, 12)
        self.assertEqual(pe.verifyEngine(out)[2], 12)
        self.assertEqual(sorted(plan)[:2], ["bin/clang++.exe", "bin/clang.exe"])

    def test_the_resource_directory_is_carried_with_its_actual_paths(self):
        write(os.path.join(self.llvm, "lib", "clang", "22", "lib", "windows", "deep", "x.bin"), "x")
        out, *_ = self.prepare()
        self.assertEqual(read(os.path.join(out, "lib", "clang", "22", "lib", "windows", "deep", "x.bin")), "x")


class RefusalTest(World):
    def test_a_missing_or_unusable_license_is_refused_before_any_output(self):
        self.refused("--license is required: the upstream LLVM payload ships no license file", license=None)
        self.refused("--license is required", license="")
        self.refused("--license .* is not a regular file", license=self.path("licenses"))
        self.refused("--license .* is not a regular file", license=self.path("nope.txt"))
        write(self.path("empty.txt"), "")
        self.refused("--license .* is empty", license=self.path("empty.txt"))
        os.symlink(self.license, self.path("link.txt"))
        self.refused("--license .* is not a regular file", license=self.path("link.txt"))

    def test_a_missing_tool_or_a_tool_that_is_a_link_is_refused_naming_it(self):
        os.remove(os.path.join(self.bin, "llvm-nm.exe"))
        self.refused(r"%s: needs llvm-nm\.exe, which is not in" % self.llvm.replace("\\", "\\\\"))
        buildPe(os.path.join(self.bin, "llvm-nm.exe"))
        os.remove(os.path.join(self.bin, "llvm-ar.exe"))
        os.symlink("llvm-nm.exe", os.path.join(self.bin, "llvm-ar.exe"))
        self.refused(r"llvm-ar\.exe is not a regular file")

    def test_a_tool_whose_case_differs_or_that_matches_two_files_is_refused(self):
        real = pw.sourceListing
        with mock.patch.object(pw, "sourceListing", side_effect=lambda d: dict(real(d), **{"clang.exe": ["Clang.exe"]})):
            self.refused(r"holds Clang\.exe, but the tool must be named exactly clang\.exe")
        with mock.patch.object(pw, "sourceListing", side_effect=lambda d: dict(real(d), **{"clang.exe": ["clang.exe", "CLANG.EXE"]})):
            self.refused(r"matches 2 files of .* differing only by case: CLANG\.EXE, clang\.exe")

    def test_an_import_found_nowhere_is_refused_naming_the_file_and_the_import_for_normal_and_delayed_imports(self):
        self.importing("libgone.dll")
        self.refused(r"llvm-nm\.exe: needs libgone\.dll, which is not in .* and is not a system library of advapi32\.dll")
        self.importing("KERNEL32.dll", delay=["libgone.dll"])
        self.refused(r"needs libgone\.dll")
        self.dll("libfoo.dll", delayImports=["libgone2.dll"])
        self.importing("libfoo.dll")
        self.refused(r"libfoo\.dll: needs libgone2\.dll")

    def test_a_name_that_is_not_in_the_observed_allowlist_is_never_taken_as_a_system_library(self):
        for name in ("api-ms-win-crt-runtime-l1-1-0.dll", "ext-ms-win-foo.dll", "ucrtbase.dll", "msvcp140.dll", "gdi32.dll", "kernel32.dl",
                     "kernel32.dll.x", "advapi3.dll"):
            self.importing(name)
            with self.subTest(name):
                if name.endswith(".dll"):
                    self.refused(r"needs %s, which is not in" % name.replace(".", r"\."))
                else:
                    self.refused(r"imports %s, which is not a \.dll file name" % name.replace(".", r"\."))

    def test_an_import_that_is_not_a_basename_is_refused(self):
        for name in ("..\\evil.dll", "sub/x.dll", "C:\\Windows\\kernel32.dll", "a\\b.dll"):
            self.importing(name)
            with self.subTest(name):
                self.refused("imports .*, which is not a file basename")

    def test_a_drive_relative_or_stream_name_is_not_a_basename_even_when_a_file_of_that_name_exists(self):
        for name in ("C:outside.dll", "outside.dll:stream", "a:b.dll", "c:"):
            self.dll(name)
            self.importing(name)
            with self.subTest(name):
                self.refused("imports .*, which is not a file basename")
            os.remove(os.path.join(self.bin, name))

    def test_an_import_of_an_executable_or_an_extensionless_file_is_refused_even_when_it_is_in_bin(self):
        for name in ("helper.exe", "HELPER.EXE", "helper", "helper.dll.exe"):
            buildPe(os.path.join(self.bin, name))
            self.importing(name, delay=[])
            with self.subTest(name):
                self.refused(r"llvm-nm\.exe: imports %s, which is not a \.dll file name" % name.replace(".", r"\."))
            os.remove(os.path.join(self.bin, name))

    def test_a_delayed_import_of_an_executable_is_refused_too(self):
        buildPe(os.path.join(self.bin, "helper.exe"))
        self.importing("KERNEL32.dll", delay=["helper.exe"])
        self.refused(r"imports helper\.exe, which is not a \.dll file name")

    def test_a_system_library_name_in_the_source_bin_is_refused_before_any_version_or_inspector_run_even_when_nothing_imports_it(self):
        for name in ("Kernel32.dll", "NTDLL.DLL", "version.dll", "shell32.dll"):
            self.dll(name)
            with self.subTest(name):
                self.refused(r"holds %s, which would shadow the system library" % name.replace(".", r"\."))
                self.version.assert_not_called()
                self.inspect.assert_not_called()
            os.remove(os.path.join(self.bin, name))

    def test_a_source_bin_that_is_a_link_or_a_reparse_point_is_refused_before_any_version_run_or_copy(self):
        outside = self.path("outside bin")
        os.rename(self.bin, outside)
        os.symlink(outside, self.bin)
        with mock.patch.object(pw.shutil, "copyfile", side_effect=AssertionError("copy")):
            self.refused(r"bin is a symlink or reparse point")
        self.version.assert_not_called()
        os.remove(self.bin)
        os.rename(outside, self.bin)
        with reparse(self.bin):
            self.refused(r"bin is a symlink or reparse point")
        self.version.assert_not_called()

    def test_a_source_tool_that_is_a_link_or_a_reparse_point_is_refused_before_any_version_run(self):
        with reparse(os.path.join(self.bin, "llvm-ar.exe")):
            self.refused(r"llvm-ar\.exe is not a regular file")
        self.version.assert_not_called()

    def test_a_source_dll_that_is_a_reparse_point_is_refused(self):
        self.importing("libfoo.dll")
        self.dll("libfoo.dll")
        with reparse(os.path.join(self.bin, "libfoo.dll")):
            self.refused(r"libfoo\.dll is not a regular file")

    def test_a_lib_or_resource_directory_that_is_a_link_or_a_reparse_point_is_refused_before_any_version_run_or_copy(self):
        clang = os.path.join(self.llvm, "lib", "clang")
        for label, held in (("lib", os.path.join(self.llvm, "lib")), ("clang", clang), ("22", os.path.join(clang, "22")),
                            ("include", os.path.join(clang, "22", "include"))):
            outside = self.path("outside " + label)
            os.rename(held, outside)
            os.symlink(outside, held)
            with self.subTest(label, kind="symlink"), mock.patch.object(pw.shutil, "copyfile", side_effect=AssertionError("copy")):
                self.refused("symlink in resource directory: %s" % label)
                self.version.assert_not_called()
            os.remove(held)
            os.rename(outside, held)
            with self.subTest(label, kind="reparse"), reparse(held):
                self.refused("symlink in resource directory: %s" % label)
                self.version.assert_not_called()

    def test_a_dll_that_would_shadow_a_system_library_is_refused(self):
        self.dll("Kernel32.dll")
        self.importing("KERNEL32.dll")
        self.refused(r"holds Kernel32\.dll, which would shadow the system library")

    def test_two_source_dlls_that_differ_only_by_case_are_refused_when_one_is_needed(self):
        self.importing("libfoo.dll")
        self.dll("libfoo.dll")
        real = pw.sourceListing
        with mock.patch.object(pw, "sourceListing", side_effect=lambda d: dict(real(d), **{"libfoo.dll": ["libfoo.dll", "LibFoo.dll"]})):
            self.refused(r"libfoo\.dll matches 2 files of .* differing only by case: LibFoo\.dll, libfoo\.dll")

    def test_a_planned_name_that_folds_onto_another_planned_name_is_refused(self):
        plan, folds = {"bin/a.dll": "/s/a.dll"}, {"bin/a.dll": "bin/a.dll"}
        with self.assertRaisesRegex(pe.EngineError, r"bin/a\.dll and bin/A\.DLL differ only by case"):
            pw.addPlanned(plan, folds, "bin/A.DLL", "/s/A.DLL")
        with self.assertRaisesRegex(pe.EngineError, r"bin/a\.dll collides: /s/a\.dll and /t/a\.dll"):
            pw.addPlanned(plan, folds, "bin/a.dll", "/t/a.dll")
        pw.addPlanned(plan, folds, "bin/a.dll", "/s/a.dll")

    def test_a_tool_or_dll_of_the_wrong_architecture_or_role_is_refused_naming_the_file(self):
        for tool, over, text in (("llvm-ar.exe", {"machine": 0xAA64}, "machine 0xaa64"), ("llvm-ar.exe", {"machine": 0x14C}, "machine 0x14c"),
                                 ("llvm-ar.exe", {"magic": 0x10B}, "optional header magic 0x10b, not PE32\\+"), ("llvm-ar.exe", {"characteristics": DLL}, "is a DLL image"),
                                 ("llvm-ar.exe", {"characteristics": 0x2000}, "is not an executable image")):
            buildPe(os.path.join(self.bin, tool), **over)
            with self.subTest(tool=tool, over=over):
                self.refused(r"llvm-ar\.exe: %s" % text)
            buildPe(os.path.join(self.bin, tool))
        self.importing("libfoo.dll")
        self.dll("libfoo.dll", characteristics=0x22)
        self.refused(r"libfoo\.dll: is an executable image, required to be a DLL of bin/libfoo\.dll")
        self.dll("libfoo.dll", machine=0xAA64)
        self.refused(r"libfoo\.dll: machine 0xaa64")

    def test_a_tool_that_is_not_a_pe_image_is_refused(self):
        write(os.path.join(self.bin, "llvm-ar.exe"), "text, not a PE image\n", 0o755)
        self.refused(r"llvm-ar\.exe: not a PE image")

    def test_clang_and_lld_of_different_versions_or_no_version_are_refused(self):
        self.versions["ld.lld.exe"] = "22.1.0"
        self.refused("lld 22.1.0 does not match clang 22.1.1")

    def test_a_missing_resource_directory_or_required_resource_file_is_refused(self):
        os.remove(os.path.join(self.llvm, "lib", "clang", "22", "lib", "windows", "clang_rt.builtins-x86_64.lib"))
        self.refused(r"missing lib/clang/22/lib/windows/clang_rt\.builtins-x86_64\.lib")
        shutil.rmtree(os.path.join(self.llvm, "lib", "clang"))
        self.refused("missing resource directory")

    def test_every_planned_source_lies_inside_the_declared_root(self):
        with mock.patch.object(pe, "containsPath", return_value=False):
            self.refused("is outside the LLVM root")

    def test_a_symlink_in_the_resource_directory_is_refused(self):
        os.symlink("stddef.h", os.path.join(self.llvm, "lib", "clang", "22", "include", "alias.h"))
        self.refused("symlink in resource directory: alias.h")

    def test_a_missing_root_or_bin_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "--llvm-root .* is not a directory"):
            pw.prepareEngine(self.path("nope"), self.license, self.path("out", "engine"))
        shutil.rmtree(self.bin)
        self.refused("has no bin directory")

    def test_an_existing_output_is_never_replaced_and_is_not_inside_the_source_even_through_an_alias(self):
        os.makedirs(self.path("out", "engine"))
        with self.assertRaisesRegex(pe.EngineError, "never replaced"):
            self.prepare()
        for output in (os.path.join(self.llvm, "engine"), os.path.join(self.llvm, "a", "engine")):
            with self.assertRaisesRegex(pe.EngineError, "must not be inside the source root"):
                self.prepare(output=output)
        os.symlink(self.llvm, self.path("alias"))
        with mock.patch.object(pw.shutil, "copyfile", side_effect=AssertionError("copy reached inside the source")):
            with self.assertRaisesRegex(pe.EngineError, "must not be inside the source root"):
                self.prepare(output=self.path("alias", "engine"))
        self.assertEqual(sorted(os.listdir(self.llvm)), ["bin", "lib"])

    def test_an_output_claimed_while_preparing_is_never_replaced_and_leaves_no_partial_and_the_source_is_unchanged(self):
        out, original, before = self.path("out", "engine"), pe.writeContract, self.tree(self.llvm)

        def claim(*args):
            os.makedirs(out)
            return original(*args)

        with mock.patch.object(pe, "writeContract", side_effect=claim):
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                self.prepare()
        self.assertEqual(os.listdir(out), [])
        self.assertEqual(os.listdir(self.path("out")), ["engine"])
        self.assertEqual(self.tree(self.llvm), before)

    def test_on_windows_the_platform_refusal_of_an_existing_destination_is_the_same_never_replaced_error(self):
        def exists(source, destination):
            raise FileExistsError(183, "exists", destination)
        with mock.patch.object(pr.sys, "platform", "win32"), mock.patch.object(pr.os, "rename", side_effect=exists):
            self.refused("never replaced")

    def test_a_failure_while_verifying_the_copy_leaves_no_output_or_partial(self):
        with mock.patch.object(pe, "verifyEngine", side_effect=pe.EngineError("hash mismatch")):
            self.refused("hash mismatch")

    def test_only_a_native_windows_x64_host_prepares(self):
        for platform_, machine, ok in (("win32", "AMD64", True), ("win32", "amd64", True), ("win32", "ARM64", False),
                                       ("win32", "x86", False), ("darwin", "arm64", False), ("linux", "x86_64", False)):
            with self.subTest(platform=platform_, machine=machine):
                self.patchers[0].stop()
                try:
                    with mock.patch.object(pw.sys, "platform", platform_), mock.patch.object(pw.platform, "machine", return_value=machine):
                        if ok:
                            self.assertEqual(pw.detectHost(), pe.WINDOWS_X64)
                        else:
                            with self.assertRaisesRegex(pe.EngineError, "unsupported host"):
                                pw.detectHost()
                finally:
                    self.patchers[0].start()


class VerifyTest(World):
    def setUp(self):
        super().setUp()
        self.importing("libfoo.dll")
        self.dll("libfoo.dll")
        self.out = self.prepare()[0]

    def mutate(self, rel, **change):
        path = os.path.join(self.out, rel)
        mode = os.stat(path).st_mode
        fields = fieldsOf(path)
        fields.update(change)
        buildPe(path, mode=mode & 0o777, **fields)
        pe.writeContract(self.out, pe.WINDOWS_X64, "22.1.1")

    def rewrite(self):
        pe.writeContract(self.out, pe.WINDOWS_X64, "22.1.1")

    def refused(self, pattern, *args):
        with self.assertRaisesRegex(pe.EngineError, pattern):
            pe.verifyEngine(self.out, *args)

    def test_the_prepared_bundle_verifies_with_its_own_inspector_by_default(self):
        self.inspect.reset_mock()
        self.assertEqual(pe.verifyEngine(self.out), (pe.WINDOWS_X64, "22.1.1", 13))
        self.assertEqual({c.args[0] for c in self.inspect.call_args_list}, {os.path.join(self.out, "bin", "llvm-readobj.exe")})

    def test_an_explicit_inspector_replaces_the_bundled_one_and_may_come_from_another_host(self):
        explicit = buildPe(self.path("native", "llvm-readobj"))
        self.detect.side_effect = pe.EngineError("unsupported host darwin: only native Windows x86_64 is implemented")
        self.inspect.reset_mock()
        self.assertEqual(pe.verifyEngine(self.out, explicit)[2], 13)
        self.assertEqual({c.args[0] for c in self.inspect.call_args_list}, {explicit})

    def test_a_bundle_on_a_foreign_host_is_never_run_without_an_explicit_inspector(self):
        self.detect.side_effect = pe.EngineError("unsupported host darwin: only native Windows x86_64 is implemented")
        self.inspect.reset_mock()
        with mock.patch.object(pw.subprocess, "run", side_effect=AssertionError("a foreign PE was run")):
            self.refused(r"cannot run the bundle's own bin/llvm-readobj\.exe here \(unsupported host darwin.*\); pass --inspector")
        self.inspect.assert_not_called()

    def test_the_contract_is_checked_before_any_inspector_runs(self):
        write(os.path.join(self.out, "notices", "provenance.json"), "{}\n")
        self.inspect.reset_mock()
        self.refused("hash mismatch: notices/provenance.json")
        self.inspect.assert_not_called()

    def test_an_explicit_inspector_that_is_not_an_executable_file_is_refused(self):
        for inspector in (self.path("none"), self.path("tools")):
            os.makedirs(self.path("tools"), exist_ok=True)
            with self.subTest(inspector=inspector):
                self.refused("--inspector .* is not an executable file", inspector)

    def test_a_bundled_inspector_that_is_a_link_or_missing_is_refused(self):
        os.remove(os.path.join(self.out, "bin", "llvm-readobj.exe"))
        os.symlink("llvm-ar.exe", os.path.join(self.out, "bin", "llvm-readobj.exe"))
        self.rewrite()
        self.refused("bin/llvm-readobj.exe is a symlink or reparse point")
        os.remove(os.path.join(self.out, "bin", "llvm-readobj.exe"))
        self.rewrite()
        self.refused("layout: missing bin/llvm-readobj.exe")

    def test_a_bundled_inspector_or_tool_that_is_a_reparse_point_is_refused(self):
        self.inspect.reset_mock()
        with reparse(os.path.join(self.out, "bin", "llvm-readobj.exe")):
            self.refused("bin/llvm-readobj.exe is a symlink or reparse point")
        with reparse(os.path.join(self.out, "bin", "clang.exe")):
            self.refused("bin/clang.exe is a symlink or reparse point")
        self.inspect.assert_not_called()

    def test_an_import_that_is_not_a_dll_basename_is_refused_by_the_verifier(self):
        for name in ("C:outside.dll", "outside.dll:stream", "helper.exe", "helper"):
            self.mutate("bin/llvm-ar.exe", imports=["KERNEL32.dll", name])
            with self.subTest(name):
                self.refused(r"bin/llvm-ar\.exe: imports .*(which is not a file basename|which is not a \.dll file name)")

    def test_a_tool_of_the_wrong_architecture_or_role_is_refused_naming_the_file(self):
        self.mutate("bin/llvm-ar.exe", machine=0xAA64)
        self.refused(r"bin/llvm-ar\.exe: machine 0xaa64")
        self.mutate("bin/llvm-ar.exe", machine=0x8664, characteristics=DLL)
        self.refused(r"bin/llvm-ar\.exe: is a DLL image")
        self.mutate("bin/libfoo.dll", characteristics=0x22)
        self.refused(r"bin/libfoo\.dll: is an executable image, required to be a DLL")

    def test_a_file_that_is_not_a_pe_image_or_is_not_an_exe_or_dll_or_is_nested_is_refused(self):
        write(os.path.join(self.out, "bin", "llvm-ar.exe"), "text, not a PE image\n", 0o755)
        self.rewrite()
        self.refused("bin/llvm-ar.exe: not a PE image")
        self.mutate("bin/clang.exe", imports=["KERNEL32.dll"])
        shutil.copyfile(os.path.join(self.bin, "llvm-ar.exe"), os.path.join(self.out, "bin", "llvm-ar.exe"))
        write(os.path.join(self.out, "bin", "notes.txt"))
        self.rewrite()
        self.refused(r"bin/notes\.txt: bin/ holds only \.exe and \.dll files directly")
        os.remove(os.path.join(self.out, "bin", "notes.txt"))
        buildPe(os.path.join(self.out, "bin", "sub", "x.dll"), characteristics=DLL)
        self.rewrite()
        self.refused(r"bin/sub/x\.dll: bin/ holds only")

    def test_a_system_name_in_bin_or_two_names_that_fold_together_are_refused(self):
        self.dll("Kernel32.dll")
        shutil.copyfile(os.path.join(self.bin, "Kernel32.dll"), os.path.join(self.out, "bin", "Kernel32.dll"))
        self.rewrite()
        self.refused(r"bin/Kernel32\.dll would shadow the system library Kernel32\.dll")
        os.remove(os.path.join(self.out, "bin", "Kernel32.dll"))
        self.rewrite()
        listed = pe.listFiles(self.out)
        with mock.patch.object(pe, "listFiles", return_value=listed + ["bin/LIBFOO.dll"]):
            with self.assertRaisesRegex(pe.EngineError, r"bin/libfoo\.dll and bin/LIBFOO\.dll differ only by case"):
                pw.verifyEngine(self.out, pe.WINDOWS_X64, "22.1.1")

    def test_an_import_that_is_neither_in_bin_nor_a_system_name_or_not_a_basename_is_refused(self):
        self.mutate("bin/llvm-ar.exe", imports=["KERNEL32.dll", "libgone.dll"])
        self.refused(r"bin/llvm-ar\.exe: imports libgone\.dll, which is not in bin/ and is not a system library of advapi32\.dll")
        self.mutate("bin/llvm-ar.exe", imports=["..\\x.dll"], delayImports=[])
        self.refused(r"bin/llvm-ar\.exe: imports '\.\.\\\\x\.dll', which is not a file basename|imports .*not a file basename")
        self.mutate("bin/llvm-ar.exe", imports=["kernel32.DLL"], delayImports=["LIBFOO.DLL", "ole32.dll"])
        self.assertEqual(pe.verifyEngine(self.out)[2], 13)

    def test_a_changed_file_or_a_missing_layout_file_or_an_empty_license_is_refused(self):
        os.remove(os.path.join(self.out, "lib", "clang", "22", "lib", "windows", "clang_rt.builtins-x86_64.lib"))
        self.rewrite()
        self.refused(r"layout: missing lib/clang/22/lib/windows/clang_rt\.builtins-x86_64\.lib")
        write(os.path.join(self.out, "lib", "clang", "22", "lib", "windows", "clang_rt.builtins-x86_64.lib"), "!<arch>\n")
        write(os.path.join(self.out, "notices", "LICENSE.TXT"), "")
        self.rewrite()
        self.refused(r"layout: notices/LICENSE\.TXT is empty")
        os.remove(os.path.join(self.out, "notices", "LICENSE.TXT"))
        self.rewrite()
        self.refused(r"layout: missing notices/LICENSE\.TXT")

    def test_a_corrupt_manifest_is_refused_by_the_common_contract(self):
        with open(os.path.join(self.out, "bin", "clang.exe"), "ab") as f:
            f.write(b"x")
        self.refused("hash mismatch: bin/clang.exe")

    def test_a_symlink_in_bin_is_refused(self):
        os.remove(os.path.join(self.out, "bin", "libfoo.dll"))
        os.symlink("llvm-ar.exe", os.path.join(self.out, "bin", "libfoo.dll"))
        self.rewrite()
        self.refused("bin/libfoo.dll is a symlink or reparse point")

    def test_a_bundle_of_another_host_is_not_handed_to_the_windows_audit(self):
        with self.assertRaisesRegex(pe.EngineError, "is not a x86_64-windows bundle"):
            pw.verifyEngine(self.out, pe.LINUX_X64, "22.1.1")


class CommandLineTest(World):
    def test_the_command_line_prepares_and_then_verifies_a_bundle_and_the_common_command_labels_it_pe(self):
        out = self.path("cli", "engine")
        self.assertEqual(pw.main(["--llvm-root", self.llvm, "--license", self.license, "--output", out]), 0)
        self.assertEqual(pw.main(["--verify", out]), 0)
        self.assertEqual(pw.main(["--verify", out, "--inspector", self.inspector]), 0)
        self.assertEqual(pw.main(["--llvm-root", self.llvm, "--license", self.license, "--output", out]), 1)
        with mock.patch("sys.stdout", new_callable=io.StringIO) as printed:
            self.assertEqual(pe.main(["--verify", out]), 0)
        self.assertEqual(printed.getvalue(), "verified host=x86_64-windows version=22.1.1 pe=12\n")

    def test_the_license_is_required_on_the_command_line_and_a_missing_one_is_named(self):
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(pw.main(["--llvm-root", self.llvm, "--output", self.path("cli", "engine")]), 1)
        self.assertIn("prepareWindowsEngine: error: --license is required", err.getvalue())
        with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
            pw.main(["--license", self.license, "--output", self.path("cli", "x")])

    def test_verify_names_a_bundle_of_another_host_instead_of_labelling_it(self):
        mac = self.path("mac")
        write(os.path.join(mac, "bin", "tool"), "tool\n")
        pe.writeContract(mac, "aarch64-macos", "22.1.1")
        with mock.patch("sys.stderr", new_callable=io.StringIO) as err:
            self.assertEqual(pw.main(["--verify", mac]), 1)
        self.assertIn("is a aarch64-macos bundle, not x86_64-windows", err.getvalue())

    def test_the_callers_that_pass_the_engine_root_alone_read_a_windows_bundle_through_the_common_api(self):
        out = self.prepare()[0]
        self.assertEqual(pr.engineMajor(out), (pe.WINDOWS_X64, "22.1.1", "22"))


if __name__ == "__main__":
    unittest.main()
