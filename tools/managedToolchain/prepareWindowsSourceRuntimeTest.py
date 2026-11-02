import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe
import prepareRuntime as pr
import prepareWindowsRuntime as pw
import prepareWindowsSourceRuntime as ps

GOOD_IMPORTS = {"machine": pw.MACHINE_AMD64, "subsystem": pw.SUBSYSTEM_CONSOLE, "characteristics": 0x22,
                "imports": {"kernel32.dll": [], "api-ms-win-crt-math-l1-1-0.dll": []}, "exports": []}


def write(path, content="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb" if isinstance(content, bytes) else "w") as f:
        f.write(content)


def read(path):
    with open(path) as f:
        return f.read()


def coff(machine):
    return struct.pack("<HHIIIHH", machine, 0, 0, 0, 0, 0, 0)


def importMember(machine):
    return struct.pack("<HHHH", 0, 0xFFFF, 0, machine) + bytes(12)


def archive(members):
    data = b"!<arch>\n"
    for name, body in members:
        header = (name + "/").ljust(16) + "0".ljust(12) + "0".ljust(6) + "0".ljust(6) + "644".ljust(8) \
            + str(len(body)).ljust(10) + "`\n"
        data += header.encode("ascii") + body + (b"\n" if len(body) % 2 else b"")
    return data


class TempCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="prepareWindowsSourceRuntimeTest-")
        self.dir = os.path.realpath(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)


def gitRepository(root, files):
    """A repository with files committed. Returns its commit hash."""
    for name, content in files.items():
        write(os.path.join(root, name), content)
    environment = dict(os.environ, GIT_AUTHOR_NAME="t", GIT_AUTHOR_EMAIL="t@t", GIT_COMMITTER_NAME="t",
                       GIT_COMMITTER_EMAIL="t@t")
    for command in (["init", "-q"], ["add", "."], ["commit", "-q", "-m", "test: pin source fixture"]):
        subprocess.run(["git", "-C", root] + command, check=True, env=environment, stdout=subprocess.PIPE)
    return subprocess.run(["git", "-C", root, "rev-parse", "HEAD"], check=True, stdout=subprocess.PIPE,
                          universal_newlines=True).stdout.strip()


class SourceRootTest(TempCase):
    def setUp(self):
        super().setUp()
        self.root = self.path("src")
        self.rev = gitRepository(self.root, {"a/marker": "m", "b": "b"})

    def test_a_clean_checkout_at_the_pinned_commit_is_accepted(self):
        self.assertEqual(ps.checkSourceRoot(self.root, self.rev, "mingw-w64", ["a/marker"]), os.path.realpath(self.root))

    def test_another_commit_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "not the pinned"):
            ps.checkSourceRoot(self.root, "0" * 40, "mingw-w64", ["a/marker"])

    def test_a_revision_that_is_not_a_full_hash_is_refused(self):
        for rev in ("master", self.rev[:12], self.rev.upper(), None, ""):
            with self.assertRaisesRegex(pe.EngineError, "full lowercase commit hash"):
                ps.checkSourceRoot(self.root, rev, "mingw-w64", [])

    def test_an_untracked_or_a_changed_file_is_refused(self):
        write(os.path.join(self.root, "new"))
        with self.assertRaisesRegex(pe.EngineError, "uncommitted or untracked"):
            ps.checkSourceRoot(self.root, self.rev, "mingw-w64", [])
        os.remove(os.path.join(self.root, "new"))
        write(os.path.join(self.root, "b"), "changed")
        with self.assertRaisesRegex(pe.EngineError, "uncommitted or untracked"):
            ps.checkSourceRoot(self.root, self.rev, "mingw-w64", [])

    def test_a_missing_marker_and_a_tree_that_is_not_a_checkout_are_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "lacks a/absent"):
            ps.checkSourceRoot(self.root, self.rev, "mingw-w64", ["a/absent"])
        plain = self.path("plain")
        write(os.path.join(plain, "a", "marker"))
        with self.assertRaises(pe.EngineError):
            ps.checkSourceRoot(plain, self.rev, "mingw-w64", ["a/marker"])


class LlvmVersionTest(TempCase):
    VERSION = "".join("if(NOT DEFINED LLVM_VERSION_%s)\n  set(LLVM_VERSION_%s %d)\nendif()\n" % (p, p, n)
                      for p, n in (("MAJOR", 22), ("MINOR", 1), ("PATCH", 1)))

    def llvm(self, text):
        write(os.path.join(self.dir, "cmake", "Modules", "LLVMVersion.cmake"), text)
        return self.dir

    def test_the_engine_version_is_accepted_and_another_major_minor_or_patch_refused(self):
        root = self.llvm(self.VERSION)
        ps.checkLlvmVersion(root, "22.1.1")
        for engine in ("21.1.1", "22.2.1", "22.1.2"):
            with self.assertRaisesRegex(pe.EngineError, "is LLVM 22.1.1, the engine is LLVM " + engine):
                ps.checkLlvmVersion(root, engine)

    def test_a_file_without_a_full_version_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "names no LLVM_VERSION_MAJOR, MINOR and PATCH"):
            ps.checkLlvmVersion(self.llvm("set(LLVM_VERSION_MAJOR 22)\n"), "22.1.1")


class PinTest(unittest.TestCase):
    def test_the_pins_are_full_hashes_and_used_when_no_revision_is_given(self):
        self.assertRegex(ps.MINGW_W64_PIN, ps.SHA1)
        for version, rev in ps.LLVM_PINS.items():
            self.assertRegex(rev, ps.SHA1, msg=version)
        for version in ("22.1.1", "23.1.0"):
            self.assertEqual(ps.pinnedRevisions(version), (ps.MINGW_W64_PIN, ps.LLVM_PINS[version]))
        self.assertEqual(ps.LLVM_PINS["23.1.0"], "ea7d852a70e8bdfaf601d6626a760f9771b2c4b4")

    def test_an_explicit_revision_wins_and_an_unpinned_engine_version_needs_one(self):
        self.assertEqual(ps.pinnedRevisions("22.1.1", "a" * 40, "b" * 40), ("a" * 40, "b" * 40))
        self.assertEqual(ps.pinnedRevisions("99.0.0", None, "c" * 40)[1], "c" * 40)
        with self.assertRaisesRegex(pe.EngineError, "no llvm-project pin for engine LLVM 99.0.0"):
            ps.pinnedRevisions("99.0.0")


@unittest.skipIf(os.name == "nt", "source builds require POSIX")
class WinpthreadsBuildTest(TempCase):
    def setUp(self):
        super().setUp()
        self.engine, self.mingw, self.work = self.path("engine"), self.path("mingw"), self.path("work")
        self.headers, self.tools = self.path("headers"), {"sh": "/bin/sh", "make": "/bin/make"}
        os.makedirs(self.work)
        for name in ("clang", "llvm-ar", "llvm-ranlib", "llvm-dlltool", "ld.lld", "llvm-rc"):
            write(os.path.join(self.engine, "bin", name))
        self.commands, self.alias = [], b"static archive"

    def build(self, target):
        prefix = os.path.join(self.work, target + "-winpthreads")
        def run(command, cwd, environment, log):
            self.commands.append((command, cwd, environment, log))
            if command == [self.tools["make"], "install"]:
                write(os.path.join(prefix, "lib", "libwinpthread.a"), b"static archive")
                if self.alias is not None:
                    write(os.path.join(prefix, "lib", "libpthread.a"), self.alias)
        with mock.patch.object(ps, "runBuild", side_effect=run):
            return ps.buildWinpthreads(self.mingw, self.engine, "23", self.headers, target, self.work,
                                      self.tools, {"HOME": self.work}, 2)

    def test_upstream_static_configure_make_and_install_receive_only_prepared_tools_for_both_cpus(self):
        for target, spec in ps.SOURCE_TARGETS.items():
            paths = self.build(target)
            configure, make, install = [c[0] for c in self.commands[-3:]]
            self.assertEqual(configure[:2], ["/bin/sh", os.path.join(self.mingw, "mingw-w64-libraries", "winpthreads", "configure")])
            for word in ("--host=" + spec["host"], "--disable-shared", "--enable-static", "CFLAGS=-O2"):
                self.assertIn(word, configure)
            assignments = dict(word.split("=", 1) for word in configure[2:] if "=" in word)
            self.assertIn("--target=" + spec["clangTarget"], assignments["CC"])
            self.assertIn("--no-default-config", assignments["CC"])
            self.assertIn("--ld-path=" + os.path.join(self.engine, "bin", "ld.lld"), assignments["CC"])
            self.assertEqual(assignments["AR"], os.path.join(self.engine, "bin", "llvm-ar") + " --format=gnu")
            self.assertEqual(assignments["RANLIB"], os.path.join(self.engine, "bin", "llvm-ranlib"))
            self.assertEqual(assignments["DLLTOOL"], os.path.join(self.engine, "bin", "llvm-dlltool"))
            self.assertEqual(os.path.basename(assignments["RC"]), spec["host"] + "-windres")
            self.assertEqual(os.path.realpath(assignments["RC"]), os.path.join(self.engine, "bin", "llvm-rc"))
            self.assertIn("--preprocessor=" + os.path.join(self.engine, "bin", "clang"), assignments["RCFLAGS"])
            for word in ps.compilerFlags(self.engine, "23", spec, self.headers) + ["-E", "-xc", "-DRC_INVOKED"]:
                self.assertIn("--preprocessor-arg=" + word, assignments["RCFLAGS"])
            self.assertEqual((make, install), (["/bin/make", "-j2"], ["/bin/make", "install"]))
            self.assertEqual([os.path.basename(p) for p in paths], ["libwinpthread.a", "libpthread.a"])
            self.assertTrue(all(c[2] == {"HOME": self.work} for c in self.commands[-3:]))

    def test_missing_or_changed_installed_alias_is_refused_instead_of_repaired(self):
        for target, alias in ((pw.TARGET, None), (pw.ARM64_TARGET, b"other archive")):
            self.alias = alias
            with self.assertRaisesRegex(pe.EngineError, "pthread alias"):
                self.build(target)


class MachineTest(TempCase):
    def test_a_plain_object_and_an_import_member_report_their_machine(self):
        self.assertEqual(ps.objectMachine(coff(pw.MACHINE_ARM64)), pw.MACHINE_ARM64)
        self.assertEqual(ps.objectMachine(importMember(pw.MACHINE_AMD64)), pw.MACHINE_AMD64)
        with self.assertRaisesRegex(pe.EngineError, "bytes"):
            ps.objectMachine(b"BC")

    def test_every_member_of_an_archive_must_be_the_targets(self):
        good = self.path("good.a")
        write(good, archive([("a.o", coff(pw.MACHINE_AMD64)), ("b.o", importMember(pw.MACHINE_AMD64))]))
        self.assertIsNone(ps.machineProblem(good, pw.MACHINE_AMD64))
        bad = self.path("bad.a")
        write(bad, archive([("a.o", coff(pw.MACHINE_AMD64)), ("wrong.o", coff(pw.MACHINE_ARM64))]))
        self.assertIn("member wrong.o has machine 0xaa64, not 0x8664", ps.machineProblem(bad, pw.MACHINE_AMD64))

    def test_an_object_file_and_an_empty_archive(self):
        write(self.path("crt2.o"), coff(pw.MACHINE_ARM64))
        self.assertIsNone(ps.machineProblem(self.path("crt2.o"), pw.MACHINE_ARM64))
        self.assertIn("0xaa64", ps.machineProblem(self.path("crt2.o"), pw.MACHINE_AMD64))
        write(self.path("empty.a"), b"!<arch>\n")
        self.assertIsNone(ps.machineProblem(self.path("empty.a"), pw.MACHINE_AMD64))


class BuiltinsNameTest(unittest.TestCase):
    def test_each_target_names_the_builtins_the_driver_reads_from_the_resource_directory(self):
        self.assertEqual(ps.resourcePath(pw.TARGET), "lib/windows/libclang_rt.builtins-x86_64.a")
        self.assertEqual(ps.resourcePath(pw.ARM64_TARGET), "lib/windows/libclang_rt.builtins-aarch64.a")


class TargetFilesTest(TempCase):
    def files(self, target=pw.TARGET, skip=(), machine=None):
        machine = machine or pw.TARGETS[target]["machine"]
        found = {}
        for name in ps.REQUIRED_OBJECTS:
            write(self.path(name), coff(machine))
            found[name] = self.path(name)
        for stem in ps.REQUIRED_LIBRARIES:
            name = "lib%s.a" % stem
            write(self.path(name), archive([("m.o", coff(machine))]))
            found[name] = self.path(name)
        return {n: p for n, p in found.items() if n not in skip}

    def test_a_complete_target_passes(self):
        ps.checkTargetFiles(self.files(), pw.TARGET)
        ps.checkTargetFiles(self.files(pw.ARM64_TARGET), pw.ARM64_TARGET)

    def test_a_missing_startup_object_or_tail_archive_is_named(self):
        with self.assertRaisesRegex(pe.EngineError, "lacks crt2u.o"):
            ps.checkTargetFiles(self.files(skip=("crt2u.o",)), pw.TARGET)
        with self.assertRaisesRegex(pe.EngineError, "lacks libwinpthread.a"):
            ps.checkTargetFiles(self.files(skip=("libwinpthread.a",)), pw.TARGET)

    def test_the_objects_around_the_startup_object_are_required_and_never_left_to_a_bare_file_name(self):
        for name in ("crtbegin.o", "crtend.o"):
            with self.assertRaisesRegex(pe.EngineError, "lacks " + name):
                ps.checkTargetFiles(self.files(skip=(name,)), pw.TARGET)

    def test_the_driver_and_runtime_dependency_libraries_are_required(self):
        self.assertEqual(ps.REQUIRED_LIBRARIES, [
            "mingw32", "moldname", "mingwex", "msvcrt", "winpthread", "pthread", "synchronization", "ssp", "ssp_nonshared", "advapi32",
            "shell32", "user32", "kernel32"])
        for stem in ps.REQUIRED_LIBRARIES:
            with self.assertRaisesRegex(pe.EngineError, "lacks lib%s.a" % stem):
                ps.checkTargetFiles(self.files(skip=("lib%s.a" % stem,)), pw.TARGET)

    def test_synchronization_is_required_for_sanitizer_dependent_libraries_on_both_cpus(self):
        for target in pw.TARGETS:
            with self.assertRaisesRegex(pe.EngineError, "lacks libsynchronization.a"):
                ps.checkTargetFiles(self.files(target, skip=("libsynchronization.a",)), target)

    def test_both_stack_protector_archives_are_required_of_every_target(self):
        self.assertEqual(ps.SSP_ARCHIVES, ["libssp.a", "libssp_nonshared.a"])
        for target in pw.TARGETS:
            for name in ps.SSP_ARCHIVES:
                with self.assertRaisesRegex(pe.EngineError, "lacks " + name):
                    ps.checkTargetFiles(self.files(target, skip=(name,)), target)

    def test_a_file_of_the_other_architecture_is_refused(self):
        with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not 0xaa64"):
            ps.checkTargetFiles(self.files(pw.ARM64_TARGET, machine=pw.MACHINE_AMD64), pw.ARM64_TARGET)

    def test_collected_files_keep_other_names_out_and_refuse_a_duplicate(self):
        libraries = self.path("lib")
        write(os.path.join(libraries, "crt2.o"), coff(pw.MACHINE_AMD64))
        write(os.path.join(libraries, "libx.a"), b"!<arch>\n")
        write(os.path.join(libraries, "notes.txt"))
        write(self.path("th", "libwinpthread.a"), b"!<arch>\n")
        files, leftOut = ps.collectFiles(libraries, [self.path("th", "libwinpthread.a")])
        self.assertEqual(sorted(files), ["crt2.o", "libwinpthread.a", "libx.a"])
        self.assertEqual(leftOut, ["notes.txt"])
        write(os.path.join(libraries, "libwinpthread.a"), b"!<arch>\n")
        with self.assertRaisesRegex(pe.EngineError, "libwinpthread.a is made twice"):
            ps.collectFiles(libraries, [self.path("th", "libwinpthread.a")])


class SspArchivesTest(TempCase):
    """provideSspArchives with an llvm-ar that writes the empty archive the real one writes."""

    def setUp(self):
        super().setUp()
        self.libraries = self.path("lib")
        os.makedirs(self.libraries)
        self.commands = []
        patcher = mock.patch.object(pe, "run", side_effect=self.fakeAr)
        patcher.start()
        self.addCleanup(patcher.stop)

    def fakeAr(self, command):
        self.commands.append(command)
        write(command[-1], pr.EMPTY_ARCHIVE)
        return ""

    def contents(self, name):
        with open(os.path.join(self.libraries, name), "rb") as f:
            return f.read()

    def installed(self, *names):
        for name in names:
            write(os.path.join(self.libraries, name), archive([(name + ".o", coff(pw.MACHINE_AMD64))]))

    def test_both_archives_are_made_empty_when_the_install_has_neither(self):
        records = ps.provideSspArchives("/e", self.libraries)
        self.assertEqual([r["name"] for r in records], ["libssp.a", "libssp_nonshared.a"])
        self.assertEqual([c[:3] for c in self.commands], [[os.path.join("/e", "bin", "llvm-ar"), "--format=gnu", "crs"]] * 2)
        for record in records:
            path = os.path.join(self.libraries, record["name"])
            self.assertEqual(pe.sha256File(path), record["sha256"])
            with open(path, "rb") as f:
                self.assertEqual(f.read(), pr.EMPTY_ARCHIVE)

    def test_the_made_pair_is_collected_and_holds_no_member_of_another_machine(self):
        ps.provideSspArchives("/e", self.libraries)
        files, _ = ps.collectFiles(self.libraries, [])
        self.assertEqual(sorted(files), ps.SSP_ARCHIVES)
        for path in files.values():
            self.assertIsNone(ps.machineProblem(path, pw.MACHINE_ARM64))

    def test_an_installed_pair_is_kept_byte_for_byte_and_no_archive_is_made(self):
        self.installed(*ps.SSP_ARCHIVES)
        before = {n: self.contents(n) for n in ps.SSP_ARCHIVES}
        self.assertEqual(ps.provideSspArchives("/e", self.libraries), [])
        self.assertEqual(self.commands, [])
        self.assertEqual({n: self.contents(n) for n in ps.SSP_ARCHIVES}, before)

    def test_one_archive_of_the_two_is_refused_and_neither_is_completed_nor_replaced(self):
        for name, other in (("libssp.a", "libssp_nonshared.a"), ("libssp_nonshared.a", "libssp.a")):
            for leftover in os.listdir(self.libraries):
                os.remove(os.path.join(self.libraries, leftover))
            self.installed(name)
            before = self.contents(name)
            with self.assertRaisesRegex(pe.EngineError, "holds %s but not %s; the pair is never completed" % (name, other)):
                ps.provideSspArchives("/e", self.libraries)
            self.assertEqual(os.listdir(self.libraries), [name])
            self.assertEqual(self.contents(name), before)
        self.assertEqual(self.commands, [])

    def test_a_name_that_is_not_a_regular_file_or_is_a_link_is_refused(self):
        self.installed("libssp_nonshared.a")
        os.makedirs(os.path.join(self.libraries, "libssp.a"))
        with self.assertRaisesRegex(pe.EngineError, "libssp.a is not a regular file"):
            ps.provideSspArchives("/e", self.libraries)
        os.rmdir(os.path.join(self.libraries, "libssp.a"))
        self.installed("libssp.a")
        link = os.path.normpath(os.path.join(self.libraries, "libssp_nonshared.a"))
        real = pe.isLinkLike
        with mock.patch.object(pe, "isLinkLike", side_effect=lambda p: os.path.normpath(p) == link or real(p)):
            with self.assertRaisesRegex(pe.EngineError, "libssp_nonshared.a is not a regular file"):
                ps.provideSspArchives("/e", self.libraries)
        self.assertEqual(self.commands, [])


class ResourceTest(TempCase):
    """stageBuiltins, installResource and stageTree on a runtime whose receipt lists only its resource files."""

    def runtime(self, targets=(pw.TARGET,)):
        windows = self.path("windows")
        records = []
        for target in targets:
            built = self.path("built", ps.builtinsName(target))
            write(built, archive([("b.o", coff(pw.TARGETS[target]["machine"]))]))
            records.append(ps.stageBuiltins(built, target, windows))
        self.writeReceipt(windows, targets, records)
        return windows, records

    def readReceipt(self, windows):
        return json.loads(read(os.path.join(windows, "notices", pw.PROVENANCE)))

    def writeReceipt(self, windows, targets, records, variants=()):
        receipt = {"kind": ps.RECEIPT_KIND, "targets": list(targets), "engineRelative": ps.ENGINE_RELATIVE,
                   "variants": list(variants), "resourceFiles": records, "sources": {"llvm-project": {"major": "22"}}}
        write(os.path.join(windows, "notices", pw.PROVENANCE), json.dumps(receipt))

    def test_the_builtins_are_staged_under_the_resource_layout_with_hash_and_machine(self):
        windows, records = self.runtime((pw.TARGET, pw.ARM64_TARGET))
        self.assertEqual([r["path"] for r in records], ["lib/windows/libclang_rt.builtins-x86_64.a",
                                                        "lib/windows/libclang_rt.builtins-aarch64.a"])
        self.assertEqual([r["machine"] for r in records], ["0x8664", "0xaa64"])
        for record in records:
            staged = os.path.join(windows, "resource", *record["path"].split("/"))
            self.assertEqual(record["sha256"], pe.sha256File(staged))
            self.assertEqual(record["bytes"], os.path.getsize(staged))

    def test_builtins_of_the_other_architecture_are_refused_when_staged(self):
        built = self.path("built", ps.builtinsName(pw.ARM64_TARGET))
        write(built, archive([("b.o", coff(pw.MACHINE_AMD64))]))
        with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not 0xaa64"):
            ps.stageBuiltins(built, pw.ARM64_TARGET, self.path("windows"))
        self.assertFalse(os.path.exists(self.path("windows", "resource")))

    def test_install_copies_every_file_to_the_resource_directory_and_leaves_the_runtime_alone(self):
        windows, records = self.runtime((pw.TARGET, pw.ARM64_TARGET))
        root = self.path("engine", "lib", "clang", "22")
        write(os.path.join(root, "include", "stddef.h"))
        self.assertEqual(ps.installResource(windows, root), [r["path"] for r in records])
        for record in records:
            self.assertEqual(pe.sha256File(os.path.join(root, *record["path"].split("/"))), record["sha256"])
        self.assertEqual(os.listdir(os.path.join(windows, "resource", "lib", "windows")), [
            "libclang_rt.builtins-aarch64.a", "libclang_rt.builtins-x86_64.a"])

    def test_install_accepts_a_file_with_the_same_bytes_and_refuses_one_with_other_bytes_before_copying_any(self):
        windows, records = self.runtime((pw.TARGET, pw.ARM64_TARGET))
        root = self.path("engine", "lib", "clang", "22")
        os.makedirs(os.path.join(root, "lib", "windows"))
        shutil.copyfile(os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-x86_64.a"),
                        os.path.join(root, "lib", "windows", "libclang_rt.builtins-x86_64.a"))
        ps.installResource(windows, root)
        os.remove(os.path.join(root, "lib", "windows", "libclang_rt.builtins-aarch64.a"))
        write(os.path.join(root, "lib", "windows", "libclang_rt.builtins-x86_64.a"), b"other")
        with self.assertRaisesRegex(pe.EngineError, "already exists with other contents"):
            ps.installResource(windows, root)
        self.assertFalse(os.path.exists(os.path.join(root, "lib", "windows", "libclang_rt.builtins-aarch64.a")))

    def test_install_refuses_a_builtins_library_of_the_per_target_layout_the_driver_would_read_first(self):
        windows, _ = self.runtime()
        root = self.path("engine", "lib", "clang", "22")
        write(os.path.join(root, "lib", "x86_64-w64-windows-gnu", "libclang_rt.builtins.a"), b"!<arch>\n")
        with self.assertRaisesRegex(pe.EngineError, "would be linked instead of lib/windows/libclang_rt.builtins-x86_64.a"):
            ps.installResource(windows, root)
        self.assertFalse(os.path.exists(os.path.join(root, "lib", "windows")))

    def test_install_refuses_a_staged_file_that_changed_and_a_file_the_receipt_does_not_list(self):
        windows, records = self.runtime()
        staged = os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-x86_64.a")
        write(os.path.join(windows, "resource", "lib", "windows", "extra.a"), b"!<arch>\n")
        with self.assertRaisesRegex(pe.EngineError, "resource files .* are not the receipt's"):
            ps.installResource(windows, self.path("root"))
        os.remove(os.path.join(windows, "resource", "lib", "windows", "extra.a"))
        with open(staged, "ab") as f:
            f.write(b"x")
        with self.assertRaisesRegex(pe.EngineError, "resource/lib/windows/libclang_rt.builtins-x86_64.a does not match"):
            ps.installResource(windows, self.path("root"))
        self.assertFalse(os.path.exists(self.path("root")))

    def test_install_refuses_a_file_of_the_wrong_machine_a_wrong_name_and_a_target_the_receipt_lacks(self):
        windows = self.path("windows")
        staged = os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-aarch64.a")
        write(staged, archive([("b.o", coff(pw.MACHINE_AMD64))]))
        record = {"target": pw.ARM64_TARGET, "path": ps.resourcePath(pw.ARM64_TARGET), "machine": "0xaa64",
                  "sha256": pe.sha256File(staged), "bytes": os.path.getsize(staged)}
        self.writeReceipt(windows, [pw.ARM64_TARGET], [record])
        with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not 0xaa64"):
            ps.installResource(windows, self.path("root"))
        self.writeReceipt(windows, [pw.ARM64_TARGET], [dict(record, path="lib/windows/libclang_rt.builtins-x86_64.a")])
        with self.assertRaisesRegex(pe.EngineError, "is not lib/windows/libclang_rt.builtins-aarch64.a"):
            ps.installResource(windows, self.path("root"))
        self.writeReceipt(windows, [pw.TARGET], [record])
        with self.assertRaisesRegex(pe.EngineError, "is not of a receipt target"):
            ps.installResource(windows, self.path("root"))

    def test_a_receipt_without_resource_files_is_refused(self):
        windows = self.path("windows")
        self.writeReceipt(windows, [pw.TARGET], [])
        with self.assertRaisesRegex(pe.EngineError, "lists no resource file"):
            ps.installResource(windows, self.path("root"))

    def test_a_duplicate_and_a_missing_resource_target_are_refused_before_any_path_is_opened(self):
        windows, records = self.runtime((pw.TARGET, pw.ARM64_TARGET))
        with mock.patch.object(ps.pe, "sha256File", side_effect=AssertionError("a path was hashed")):
            self.writeReceipt(windows, [pw.TARGET, pw.ARM64_TARGET], [records[0], records[0]])
            self.assertIn("more than once", ps.receiptProblem(self.readReceipt(windows), windows))
            self.writeReceipt(windows, [pw.TARGET, pw.ARM64_TARGET], [records[0]])
            self.assertIn("lack aarch64-windows-gnu", ps.receiptProblem(self.readReceipt(windows), windows))
            self.writeReceipt(windows, [pw.TARGET], [dict(records[0], path="../x.a")])
            self.assertIn("is not lib/windows/libclang_rt.builtins-x86_64.a",
                          ps.receiptProblem(self.readReceipt(windows), windows))

    def test_a_variant_record_must_name_the_canonical_directory_and_a_plain_file_name_before_it_is_opened(self):
        windows, records = self.runtime()
        variant = {"target": pw.TARGET, "variant": "exe", "directory": ps.variantDirectory(pw.TARGET, "exe"),
                   "files": [{"name": "crt2.o", "sha256": "0" * 64}]}
        with mock.patch.object(ps.pe, "sha256File", side_effect=AssertionError("a path was hashed")):
            for change, text in ((dict(variant, directory="../engine"), "variant directory"),
                                 (dict(variant, variant="wide"), "is not a variant"),
                                 (dict(variant, target=pw.ARM64_TARGET), "is not a variant"),
                                 (dict(variant, files=[{"name": "../x.o", "sha256": "0"}]), "unsupported file name")):
                self.writeReceipt(windows, [pw.TARGET], records, [change])
                self.assertIn(text, ps.receiptProblem(self.readReceipt(windows), windows))

    def test_builtins_that_are_empty_or_only_import_members_are_refused_for_each_architecture(self):
        for target in pw.TARGETS:
            machine = pw.TARGETS[target]["machine"]
            name = ps.builtinsName(target)
            write(self.path("empty", name), b"!<arch>\n")
            self.assertIn("holds no member", ps.builtinsProblem(self.path("empty", name), machine))
            write(self.path("imports", name), archive([("i.o", importMember(machine))]))
            self.assertIn("import member", ps.builtinsProblem(self.path("imports", name), machine))
            write(self.path("good", name), archive([("b.o", coff(machine))]))
            self.assertIsNone(ps.builtinsProblem(self.path("good", name), machine))
            other = pw.MACHINE_AMD64 if machine == pw.MACHINE_ARM64 else pw.MACHINE_ARM64
            self.assertIn("not 0x%x" % other, ps.builtinsProblem(self.path("good", name), other))
            with self.assertRaisesRegex(pe.EngineError, "holds no member"):
                ps.stageBuiltins(self.path("empty", name), target, self.path("windows"))
        write(self.path("obj", "crt2.o"), coff(pw.MACHINE_AMD64))
        with self.assertRaisesRegex(pe.EngineError, "not an ar archive"):
            ps.builtinsProblem(self.path("obj", "crt2.o"), pw.MACHINE_AMD64)

    def linkAt(self, path):
        """A patch under which path is a junction or other reparse point that os.path.islink does not see."""
        path = os.path.normpath(path)
        real = pe.isLinkLike
        return mock.patch.object(ps.pe, "isLinkLike", side_effect=lambda p: os.path.normpath(p) == path or real(p))

    def test_a_reparse_point_in_the_staged_resource_or_the_receipt_is_refused_where_islink_is_false(self):
        windows, _ = self.runtime()
        root = self.path("engine")
        for link in (os.path.join(windows, "resource"), os.path.join(windows, "resource", "lib"),
                     os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-x86_64.a"),
                     os.path.join(windows, "notices", pw.PROVENANCE)):
            with self.linkAt(link), self.assertRaisesRegex(pe.EngineError, "is a link"):
                ps.installResource(windows, root)
            self.assertFalse(os.path.exists(root))

    def test_a_reparse_point_in_the_destination_is_refused_and_nothing_is_copied(self):
        windows, _ = self.runtime((pw.TARGET, pw.ARM64_TARGET))
        root = self.path("engine")
        os.makedirs(os.path.join(root, "lib", "windows"))
        for link in (root, os.path.join(root, "lib"), os.path.join(root, "lib", "windows")):
            with self.linkAt(link), self.assertRaisesRegex(pe.EngineError, "is a link"):
                ps.installResource(windows, root)
            self.assertEqual(os.listdir(os.path.join(root, "lib", "windows")), [])
        destination = os.path.join(root, "lib", "windows", "libclang_rt.builtins-x86_64.a")
        shutil.copyfile(os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-x86_64.a"), destination)
        with self.linkAt(destination), self.assertRaisesRegex(pe.EngineError, "is a link"):
            ps.installResource(windows, root)
        self.assertFalse(os.path.exists(os.path.join(root, "lib", "windows", "libclang_rt.builtins-aarch64.a")))

    def test_a_symlink_in_the_staged_resource_is_refused(self):
        windows, _ = self.runtime()
        staged = os.path.join(windows, "resource", "lib", "windows", "libclang_rt.builtins-x86_64.a")
        os.rename(staged, self.path("real.a"))
        try:
            os.symlink(self.path("real.a"), staged)
        except (OSError, NotImplementedError):
            self.skipTest("this host cannot create symlinks")
        with self.assertRaisesRegex(pe.EngineError, "is a link"):
            ps.installResource(windows, self.path("engine"))

    def test_a_copy_that_does_not_read_back_as_the_receipts_hash_is_an_error(self):
        windows, _ = self.runtime()
        real = shutil.copyfile
        def changed(source, destination):
            result = real(source, destination)
            with open(destination, "ab") as stream:
                stream.write(b"x")
            return result

        with mock.patch.object(ps.shutil, "copyfile", side_effect=changed):
            with self.assertRaisesRegex(pe.EngineError, "written with other contents"):
                ps.installResource(windows, self.path("engine"))

    def test_an_unlisted_link_in_the_staged_resource_is_refused(self):
        windows, _ = self.runtime()
        with self.linkAt(os.path.join(windows, "resource", "lib", "extra")):
            os.makedirs(os.path.join(windows, "resource", "lib", "extra"))
            with self.assertRaisesRegex(pe.EngineError, "is a link"):
                ps.installResource(windows, self.path("engine"))

    def test_the_staged_tree_has_the_builtins_in_the_copy_and_never_in_the_engine_it_was_given(self):
        windows, records = self.runtime()
        engine = self.path("engine")
        write(os.path.join(engine, "bin", "clang"))
        write(os.path.join(engine, "lib", "clang", "22", "include", "stddef.h"))
        root = self.path("tree")
        ps.stageTree(engine, windows, root, "22")
        self.assertEqual(pe.sha256File(os.path.join(root, "lib", "clang", "22", "lib", "windows",
                                                    "libclang_rt.builtins-x86_64.a")), records[0]["sha256"])
        self.assertTrue(os.path.isfile(os.path.join(root, "runtime", "windows", "notices", pw.PROVENANCE)))
        self.assertFalse(os.path.exists(os.path.join(engine, "lib", "clang", "22", "lib")))
        self.assertEqual(sorted(os.listdir(engine)), ["bin", "lib"])

    def test_a_staged_tree_refuses_an_engine_that_already_has_a_runtime_entry(self):
        windows, _ = self.runtime()
        engine = self.path("engine")
        write(os.path.join(engine, "runtime", "x"))
        with self.assertRaisesRegex(pe.EngineError, "collides with the runtime"):
            ps.stageTree(engine, windows, self.path("tree"), "22")


class ConfigTest(unittest.TestCase):
    def render(self, target, variant):
        return ps.renderSourceConfig(target, variant, [ps.HEADER_DIRECTORY], "22")

    def lines(self, target, variant):
        return self.render(target, variant).splitlines()

    def test_the_executable_config_gives_the_driver_the_hermetic_paths_and_the_target(self):
        lines = self.lines(pw.TARGET, "exe")
        self.assertEqual(lines[:2], ["-target x86_64-w64-windows-gnu", "-Xclang -target-cpu -Xclang x86-64"])
        self.assertEqual(lines[lines.index("-nostdinc"):lines.index("-nostdinc") + 3], [
            "-nostdinc", "-isystem <CFGDIR>/../../lib/clang/22/include", "-isystem <CFGDIR>/include/libc/mingw-w64"])
        for line in ("--sysroot=<CFGDIR>/x86_64-windows-gnu", "-B<CFGDIR>/x86_64-windows-gnu",
                     "-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu", "--ld-path=<CFGDIR>/../../bin/ld.lld",
                     "-Xlinker --stack=16777216", "-Xlinker --image-base=0x140000000"):
            self.assertIn(line, lines)
        self.assertNotIn("-shared", lines)
        self.assertNotIn("zig", "\n".join(lines).lower())

    def test_the_config_leaves_the_runtime_to_the_driver(self):
        for target in pw.TARGETS:
            for variant in ps.SOURCE_VARIANTS:
                text = self.render(target, variant)
                for forbidden in ("-nostdlib", "-nodefaultlibs", "-nostartfiles", "-nolibc", "crt", "asan", "ubsan",
                                  "-fsanitize", "-static", "stack-protector", "ssp"):
                    self.assertNotIn(forbidden, text, msg=(target, variant, forbidden))
                for line in text.splitlines():
                    self.assertFalse(line.startswith(("$", "-l")) or line.endswith((".a", ".o")), msg=line)

    def test_the_driver_gets_its_own_runtime_library_and_no_unwinder(self):
        self.assertEqual(ps.DRIVER_FLAGS, ["--rtlib=compiler-rt", "--unwindlib=none"])
        for variant in ps.SOURCE_VARIANTS:
            lines = self.lines(pw.TARGET, variant)
            head = lines.index("-isystem <CFGDIR>/include/libc/mingw-w64")
            self.assertEqual(lines[head + 1:head + 3], ps.DRIVER_FLAGS)

    def test_the_dll_config_names_its_directory_shared_and_base_and_no_stack(self):
        lines = self.lines(pw.TARGET, "dll")
        self.assertIn("-shared", lines)
        self.assertIn("--sysroot=<CFGDIR>/x86_64-windows-gnu.dll", lines)
        self.assertIn("-B<CFGDIR>/x86_64-windows-gnu.dll", lines)
        self.assertIn("-Xlinker --image-base=0x180000000", lines)
        self.assertFalse([l for l in lines if "--stack" in l])

    def test_the_arm64_config_has_its_target_cpu_and_directory_and_no_x86_text(self):
        text = self.render(pw.ARM64_TARGET, "exe")
        self.assertIn("-target aarch64-w64-windows-gnu\n", text)
        self.assertIn("-Xclang -target-cpu -Xclang generic\n", text)
        self.assertIn("-B<CFGDIR>/aarch64-windows-gnu\n", text)
        self.assertNotIn("x86", text)

    def test_a_directory_beside_the_variant_directory_is_never_named(self):
        self.assertNotIn("wide", self.render(pw.TARGET, "exe"))
        self.assertEqual(list(ps.SOURCE_VARIANTS), ["exe", "dll"])

    def test_the_config_names_match_what_prepareWindowsRuntime_names(self):
        for target in pw.TARGETS:
            for variant in ("exe", "dll"):
                self.assertEqual(ps.variantConfig(target, variant), pw.variantConfig(target, variant))
                self.assertEqual(ps.variantDirectory(target, variant), pw.variantDirectory(target, variant))


class StepsTest(unittest.TestCase):
    def steps(self, target=pw.TARGET):
        return ps.sourceSteps("/e/clang", "/r/windows", "/w", target)

    def test_every_proof_is_compiled_and_linked_plain_thin_and_full(self):
        steps, outputs, bitcode, _ = self.steps()
        self.assertEqual(sorted(outputs), sorted((p, m) for p in ps.PROOFS for m in ("plain", "thin", "full")))
        for proof in ps.PROOFS:
            for mode, flag in (("thin", "-flto=thin"), ("full", "-flto=full")):
                for kind in ("compile", "link"):
                    command = dict(steps)["%s %s %s" % (proof, mode, kind)]
                    self.assertIn(flag, command)
        self.assertNotIn("-flto=thin", dict(steps)["exe plain link"])
        self.assertEqual(len(bitcode), 10)
        self.assertEqual(len(steps), 31)

    def test_the_unicode_proof_goes_through_the_executable_config_with_the_drivers_municode(self):
        steps = dict(self.steps()[0])
        self.assertEqual(sorted(ps.PROOFS), ["dll", "exe", "stack", "stackdll", "wide"])
        self.assertIn(os.path.join("/r/windows", "x86_64-windows-gnu.cfg"), steps["wide full link"])
        self.assertNotIn(os.path.join("/r/windows", "x86_64-windows-gnu.wide.cfg"), sum(steps.values(), []))
        self.assertIn("-municode", steps["wide full link"])
        self.assertNotIn("-municode", steps["exe full link"])
        self.assertTrue(steps["wide plain compile"][steps["wide plain compile"].index("-c") + 1].endswith(
            "windowsSourceWide.c"))

    def test_the_stack_proof_passes_the_protector_to_every_compile_and_every_link_and_plan(self):
        steps = dict(self.steps()[0])
        for target in ps.SOURCE_TARGETS:
            targetSteps, _, _, targetPlans = self.steps(target)
            commands = dict(targetSteps)
            for proof in ("stack", "stackdll"):
                for mode in ("plain", "thin", "full"):
                    for kind in ("compile", "link"):
                        self.assertIn("-fstack-protector-strong", commands["%s %s %s" % (proof, mode, kind)])
                self.assertIn("-fstack-protector-strong", next(c for n, c, _ in targetPlans if n == proof + " plan"))
                self.assertIn(os.path.join("/r/windows", ps.variantConfig(target, ps.PROOFS[proof]["variant"])),
                              commands[proof + " full link"])
            self.assertTrue(all(p.endswith(".dll") for (n, _), p in self.steps(target)[1].items() if n == "stackdll"))
        self.assertTrue(steps["stack plain compile"][steps["stack plain compile"].index("-c") + 1].endswith(
            "windowsSourceStack.c"))
        self.assertIn(os.path.join("/r/windows", "x86_64-windows-gnu.cfg"), steps["stack full link"])

    def test_no_other_proof_and_no_other_step_takes_a_stack_protector_flag(self):
        steps, _, _, plans = self.steps()
        for name, command in steps + [(n, c) for n, c, _ in plans]:
            self.assertEqual("-fstack-protector-strong" in command, name.startswith(("stack ", "stackdll ")), msg=name)

    def test_the_dll_link_relies_on_the_config_for_shared(self):
        steps = dict(self.steps()[0])
        self.assertIn(os.path.join("/r/windows", "x86_64-windows-gnu.dll.cfg"), steps["dll thin link"])
        self.assertNotIn("-shared", steps["dll plain link"])

    def test_every_compile_link_header_check_and_plan_disables_host_default_configs(self):
        for target in ps.SOURCE_TARGETS:
            steps, _, _, plans = self.steps(target)
            for name, command in steps + [(n, c) for n, c, _ in plans]:
                self.assertEqual(command.count("--no-default-config"), 1, msg=(target, name))

    def test_no_link_step_names_a_startup_object_a_library_or_a_runtime_suppression(self):
        for _, command in self.steps()[0]:
            for word in command:
                self.assertFalse(word.startswith(("-l", "-nostdlib", "-nostartfiles", "-nodefaultlibs", "-Wl")) or
                                 word.endswith(".a") or "crt" in os.path.basename(word), msg=word)

    def test_each_proof_has_a_driver_plan_of_its_plain_link_that_is_never_run_as_a_link(self):
        plans = self.steps()[3]
        self.assertEqual([p[2] for p in plans], ["exe", "dll", "wide", "stack", "stackdll"])
        for name, command, proof in plans:
            self.assertIn("-###", command)
            self.assertIn(os.path.join("/w", proof + "plain.o"), command)
            self.assertNotIn("-c", command)
        self.assertIn("-municode", plans[2][1])

    def test_the_abi_fixture_is_told_the_architecture(self):
        self.assertIn("-DEXPECT_AMD64", dict(self.steps(pw.TARGET)[0])["ABI headers"])
        self.assertIn("-DEXPECT_ARM64", dict(self.steps(pw.ARM64_TARGET)[0])["ABI headers"])
        self.assertIn("-fsyntax-only", dict(self.steps()[0])["ABI headers"])

    def test_the_fixtures_exist_and_the_math_ones_call_the_functions_the_pin_is_about(self):
        for name in ("windowsSourceMath.c", "windowsSourceMathDll.c", "windowsSourceWide.c", "windowsSourceAbi.c",
                     "windowsSourceStack.c", "windowsSourceStackDll.c"):
            self.assertTrue(os.path.isfile(os.path.join(pr.FIXTURES, name)), msg=name)
        for name in ("windowsSourceMath.c", "windowsSourceMathDll.c"):
            text = read(os.path.join(pr.FIXTURES, name))
            for call in ("pow(", "fmod(", "nan(", "nanl(", "isnan("):
                self.assertIn(call, text, msg=name)

    def test_the_stack_fixture_keeps_a_bounded_nonconstant_array_in_memory_where_the_optimizer_cannot_remove_it(self):
        text = read(os.path.join(pr.FIXTURES, "windowsSourceStack.c"))
        for part in ("noinline", "char bytes[16];", "(argc & 7) + 8", 'KEEP_IN_MEMORY(bytes);',
                     '__asm__ __volatile__("" : : "r"(pointer) : "memory")', 'printf("stack sum=%d\\n"'):
            self.assertIn(part, text)
        self.assertEqual(ps.EXPECTED_STACK, "stack sum=45\n")
        dll = read(os.path.join(pr.FIXTURES, "windowsSourceStackDll.c"))
        for part in ("__declspec(dllexport)", "stackSum(int length)", "length > 16", "char bytes[16]", '"memory"'):
            self.assertIn(part, dll)


def driverPlan(runtime, target, name, startup=None, drop=(), add=()):
    """The `-###` text clang prints for proof `name`: banner lines and the quoted cc1 and ld.lld lines. The tail names
    libssp_nonshared and libssp when the proof's flags carry the stack protector, as the driver does."""
    proof = ps.PROOFS[name]
    ssp = ["-lssp_nonshared", "-lssp"] if "-fstack-protector-strong" in proof["flags"] else []
    directory = os.path.join(runtime, ps.variantDirectory(target, proof["variant"]))
    words = ["/e/bin/ld.lld", "--sysroot=" + directory, "-m", "i386pep", "-Bdynamic", "-o", "/w/out.exe",
             os.path.join(directory, startup or proof["startup"]), os.path.join(directory, "crtbegin.o"),
             "-L" + directory, "/w/%splain.o" % name, "-lmingw32",
             os.path.join(os.path.normpath(os.path.join(runtime, ps.ENGINE_RELATIVE)), "lib", "clang", "22", "lib", "windows",
                          ps.builtinsName(target)), "-lmoldname", "-lmingwex", "-lmsvcrt"] + ssp + [
             "-ladvapi32", "-lshell32", "-luser32", "-lkernel32", os.path.join(directory, "crtend.o")]
    dropped = {w.replace("\\", "/") for w in drop}
    words = [w.replace("\\", "/") for w in words if w.replace("\\", "/") not in dropped]
    words += [w.replace("\\", "/") for w in add]
    return 'clang version 22.1.1\nTarget: x86_64-w64-windows-gnu\n "/e/bin/clang" "-cc1" "-x" "c"\n ' + \
        " ".join('"%s"' % w for w in words) + "\n"


class SelectionTest(unittest.TestCase):
    def problem(self, target=pw.TARGET, name="exe", **options):
        return ps.selectionProblem(driverPlan("/r/windows", target, name, **options), "/r/windows", target, name)

    def test_the_drivers_own_choices_of_every_proof_and_target_pass(self):
        for target in pw.TARGETS:
            for name in ps.PROOFS:
                self.assertIsNone(self.problem(target, name), msg=(target, name))

    def test_a_startup_object_of_another_proof_or_directory_is_named(self):
        self.assertIn("startup objects", self.problem(name="wide", startup="crt2.o"))
        self.assertIn("startup objects", self.problem(name="exe", startup="dllcrt2.o"))
        plan = driverPlan("/r/windows", pw.TARGET, "exe").replace("/r/windows/x86_64-windows-gnu/crt2.o",
                                                                 "/r/windows/other/crt2.o")
        self.assertIn("startup objects", ps.selectionProblem(plan, "/r/windows", pw.TARGET, "exe"))

    def test_a_missing_crt_object_or_tail_library_is_named(self):
        self.assertIn("does not link crtend.o", self.problem(drop=("/r/windows/x86_64-windows-gnu/crtend.o",)))
        self.assertIn("does not link crtbegin.o", self.problem(drop=("/r/windows/x86_64-windows-gnu/crtbegin.o",)))
        self.assertIn("lacks -lmsvcrt", self.problem(drop=("-lmsvcrt",)))
        self.assertIn("lacks -lkernel32", self.problem(drop=("-lkernel32",)))

    def test_the_builtins_come_from_the_engine_resource_directory_and_name_the_targets_architecture(self):
        root = os.path.normpath(os.path.join("/r/windows", ps.ENGINE_RELATIVE))
        for target in pw.TARGETS:
            path = os.path.join(root, "lib", "clang", "22", "lib", "windows", ps.builtinsName(target))
            for replacement in ((), (os.path.join("/other/lib/clang/22/lib/windows", ps.builtinsName(target)),),
                                 (os.path.join("/r/windows", target, ps.builtinsName(target)),)):
                self.assertIn("does not link " + ps.builtinsName(target),
                              self.problem(target, add=replacement, drop=(path,)))

    def test_the_default_driver_can_repeat_the_same_builtins_archive(self):
        root = os.path.normpath(os.path.join("/r/windows", ps.ENGINE_RELATIVE))
        for target in pw.TARGETS:
            path = os.path.join(root, "lib", "clang", "22", "lib", "windows", ps.builtinsName(target))
            self.assertIsNone(self.problem(target, add=(path,)))

    def test_the_stack_proof_plan_must_show_both_stack_protector_libraries_and_no_other_plan_may(self):
        for target in pw.TARGETS:
            for proof in ("stack", "stackdll"):
                plan = driverPlan("/r/windows", target, proof)
                self.assertIn('"-lssp_nonshared" "-lssp"', plan)
                self.assertIsNone(self.problem(target, proof))
                self.assertIn("lacks -lssp", self.problem(target, proof, drop=("-lssp",)))
                self.assertIn("lacks -lssp_nonshared", self.problem(target, proof, drop=("-lssp_nonshared",)))
            for name in ("exe", "dll", "wide"):
                for library in ("-lssp", "-lssp_nonshared"):
                    self.assertEqual(self.problem(target, name, add=(library,)), "the plan links " + library)

    def test_the_plan_must_name_its_compiler_version(self):
        plan = driverPlan("/r/windows", pw.TARGET, "exe").replace("clang version 22.1.1", "compiler")
        self.assertIn("compiler version", ps.selectionProblem(plan, "/r/windows", pw.TARGET, "exe"))

    def test_libgcc_and_libunwind_are_refused(self):
        for library in ("-lgcc", "-lgcc_eh", "-lgcc_s", "-lunwind"):
            self.assertEqual(self.problem(add=(library,)), "the plan links " + library)

    def test_a_plan_without_exactly_one_linker_line_is_refused(self):
        self.assertIn("0 ld.lld lines", ps.selectionProblem("clang version 22\n", "/r/windows", pw.TARGET, "exe"))
        double = driverPlan("/r/windows", pw.TARGET, "exe") * 2
        self.assertIn("2 ld.lld lines", ps.selectionProblem(double, "/r/windows", pw.TARGET, "exe"))


class PeProblemTest(unittest.TestCase):
    def test_a_ucrt_executable_of_the_right_machine_passes(self):
        self.assertIsNone(ps.sourcePeProblem("exe", GOOD_IMPORTS, pw.TARGET))
        self.assertIsNone(ps.sourcePeProblem("wide", GOOD_IMPORTS, pw.TARGET))

    def test_the_wrong_machine_subsystem_or_kind_is_named(self):
        self.assertIn("is not ARM64", ps.sourcePeProblem("exe", GOOD_IMPORTS, pw.ARM64_TARGET))
        self.assertIn("not console", ps.sourcePeProblem("exe", dict(GOOD_IMPORTS, subsystem=2), pw.TARGET))
        self.assertIn("do not match a dll", ps.sourcePeProblem("dll", GOOD_IMPORTS, pw.TARGET))
        self.assertIn("lack mathProbe", ps.sourcePeProblem("dll", dict(GOOD_IMPORTS, characteristics=0x2022),
                                                           pw.TARGET))
        self.assertIsNone(ps.sourcePeProblem("dll", dict(GOOD_IMPORTS, characteristics=0x2022, exports=["mathProbe"]),
                                             pw.TARGET))

    def test_the_stack_dll_uses_dll_characteristics_and_its_own_export_for_both_cpus(self):
        for target, spec in pw.TARGETS.items():
            info = dict(GOOD_IMPORTS, machine=spec["machine"], characteristics=0x2022, exports=["stackSum"])
            self.assertIsNone(ps.sourcePeProblem("stackdll", info, target))
            self.assertIn("lack stackSum", ps.sourcePeProblem("stackdll", dict(info, exports=["mathProbe"]), target))
            self.assertIn("do not match a dll", ps.sourcePeProblem("stackdll", dict(info, characteristics=0x22), target))

    def test_an_msvcrt_dll_import_or_no_ucrt_import_is_refused(self):
        old = dict(GOOD_IMPORTS, imports={"kernel32.dll": [], "msvcrt.dll": [], "api-ms-win-crt-math-l1-1-0.dll": []})
        self.assertIn("not the UCRT's", ps.sourcePeProblem("exe", old, pw.TARGET))
        self.assertIn("not the UCRT's", ps.sourcePeProblem("exe", dict(GOOD_IMPORTS, imports={"kernel32.dll": []}),
                                                           pw.TARGET))


class CheckSourceConfigTest(TempCase):
    """checkSourceConfig with a fake driver that writes the files the steps ask for."""

    def setUp(self):
        super().setUp()
        self.work = self.path("work")
        os.makedirs(self.work)
        self.warn = None
        self.failureOutput = None
        self.bitcode = True
        self.planOptions = {}
        self.undefined = "                 U __stack_chk_fail\n                 U printf\n"
        self.nmExit = 0
        self.commands = []
        for patcher in (mock.patch.object(pw, "readPe", return_value=GOOD_IMPORTS),
                        mock.patch.object(ps, "sourcePeProblem", return_value=None)):
            patcher.start()
            self.addCleanup(patcher.stop)

    def run_(self, command):
        self.commands.append(command)
        if os.path.basename(command[0]) == "llvm-nm":
            return subprocess.CompletedProcess(command, self.nmExit, self.undefined, "nm boom" if self.nmExit else "")
        if self.failureOutput and self.failureOutput in command[-1]:
            return subprocess.CompletedProcess(command, 1, "", "boom")
        if "-###" in command:
            name = os.path.basename(command[command.index("-###") + 1])[:-len("plain.o")]
            return subprocess.CompletedProcess(command, 0, "", driverPlan("/r/windows", pw.TARGET, name,
                                                                          **self.planOptions))
        if "-o" in command:
            output = command[command.index("-o") + 1]
            lto = any(c.startswith("-flto=") for c in command) and "-c" in command
            write(output, b"BC\xc0\xde" if lto and self.bitcode else b"MZ")
        stderr = "warning: x" if self.warn and self.warn in " ".join(command) else ""
        return subprocess.CompletedProcess(command, 0, "", stderr)

    def check(self, **options):
        return ps.checkSourceConfig(self.run_, "/e/clang", "/r/windows", self.work, pw.TARGET, **options)

    def test_every_step_runs_and_the_linked_files_come_back(self):
        outputs = self.check()
        self.assertEqual(len(outputs), 15)
        self.assertEqual(len(self.commands), 38)

    def test_the_plain_stack_object_must_leave_the_failure_handler_undefined_before_the_link_resolves_it(self):
        self.check()
        nm = [c for c in self.commands if os.path.basename(c[0]) == "llvm-nm"]
        expected = [[os.path.join("/e", "llvm-nm"), "--undefined-only", os.path.join(self.work, name + "plain.o")]
                    for name in ("stack", "stackdll")]
        self.assertEqual(nm, expected)
        for command in nm:
            self.assertTrue(any(command[-1] in c and "-c" in c for c in self.commands[:self.commands.index(command)]))
        for undefined in ("                 U printf\n", "                 T __stack_chk_fail\n", ""):
            self.undefined = undefined
            with self.assertRaisesRegex(pe.EngineError, "stack plain object: __stack_chk_fail is not among its undefined"):
                self.check()

    def test_the_dll_object_is_checked_independently_of_the_executable_object(self):
        run = self.run_
        def withoutDllGuard(command):
            if os.path.basename(command[0]) == "llvm-nm" and command[-1].endswith("stackdllplain.o"):
                return subprocess.CompletedProcess(command, 0, "U printf\n", "")
            return run(command)
        with self.assertRaisesRegex(pe.EngineError, "stackdll plain object: __stack_chk_fail"):
            ps.checkSourceConfig(withoutDllGuard, "/e/clang", "/r/windows", self.work, pw.TARGET)

    def test_an_llvm_nm_that_exits_nonzero_is_an_error(self):
        self.nmExit = 2
        with self.assertRaisesRegex(pe.EngineError, "stack symbols failed: nm boom"):
            self.check()

    def test_the_listing_names_the_symbol_only_as_an_undefined_one(self):
        self.assertIsNone(ps.undefinedProblem("                 U __stack_chk_fail\n", "__stack_chk_fail"))
        self.assertIsNone(ps.undefinedProblem("U __stack_chk_fail\n", "__stack_chk_fail"))
        for listing in ("0000000000000000 T __stack_chk_fail\n", "U __stack_chk_fail_local\n", ""):
            self.assertIn("is not among its undefined symbols", ps.undefinedProblem(listing, "__stack_chk_fail"))

    def test_a_plan_that_shows_a_startup_object_the_driver_should_not_choose_is_an_error(self):
        self.planOptions = {"startup": "crt2u.o"}
        with self.assertRaisesRegex(pe.EngineError, "exe plan: startup objects"):
            self.check()

    def test_a_plan_that_exits_nonzero_is_an_error(self):
        self.failureOutput = "dllplan.dll"
        with self.assertRaisesRegex(pe.EngineError, "dll plan failed: boom"):
            self.check()

    def test_a_nonzero_exit_or_a_warning_is_an_error(self):
        self.failureOutput = "dllfull.dll"
        with self.assertRaisesRegex(pe.EngineError, "dll full link failed: boom"):
            self.check()
        self.failureOutput, self.warn = None, "-flto=thin"
        with self.assertRaisesRegex(pe.EngineError, "warned"):
            self.check()

    def test_a_thin_lto_object_that_is_not_bitcode_is_an_error(self):
        self.bitcode = False
        with self.assertRaisesRegex(pe.EngineError, "is not LTO bitcode"):
            self.check()

    def test_a_pe_problem_names_the_file(self):
        with mock.patch.object(ps, "sourcePeProblem", return_value="machine is wrong"):
            with self.assertRaisesRegex(pe.EngineError, "dll full: machine is wrong|dll plain: machine is wrong"):
                self.check()

    def test_execute_runs_only_the_executables_and_compares_their_output(self):
        ran = []
        with mock.patch.object(ps, "canExecute", return_value=True), \
                mock.patch.object(ps, "runOutput", side_effect=lambda path, expected, name: ran.append((name, expected))):
            self.check(execute=True)
        self.assertEqual(sorted(n for n, _ in ran), sorted(
            "%s %s %s" % (pw.TARGET, v, m) for v in ("exe", "wide", "stack") for m in ("plain", "thin", "full")))
        self.assertEqual({e for _, e in ran}, {ps.EXPECTED_MATH, ps.EXPECTED_WIDE, ps.EXPECTED_STACK})

    def test_execute_on_a_host_that_cannot_run_the_target_is_an_error(self):
        with mock.patch.object(ps, "canExecute", return_value=False):
            with self.assertRaisesRegex(pe.EngineError, "cannot run"):
                self.check(execute=True)

    def test_a_wrong_output_or_exit_is_an_error(self):
        wrong = subprocess.CompletedProcess([], 0, "hello\n", "")
        with mock.patch.object(subprocess, "run", return_value=wrong):
            with self.assertRaisesRegex(pe.EngineError, "printed 'hello\\\\n'"):
                ps.runOutput("/x.exe", ps.EXPECTED_MATH, "name")
        warned = subprocess.CompletedProcess([], 0, ps.EXPECTED_MATH, "unexpected diagnostic")
        with mock.patch.object(subprocess, "run", return_value=warned):
            with self.assertRaisesRegex(pe.EngineError, "unexpected diagnostic"):
                ps.runOutput("/x.exe", ps.EXPECTED_MATH, "name")
        crashed = subprocess.CompletedProcess([], 3221225477, ps.EXPECTED_MATH, "")
        with mock.patch.object(subprocess, "run", return_value=crashed):
            with self.assertRaisesRegex(pe.EngineError, "exit 3221225477"):
                ps.runOutput("/x.exe", ps.EXPECTED_MATH, "name")


class CanExecuteTest(unittest.TestCase):
    def can(self, platformName, machine, target):
        with mock.patch.object(sys, "platform", platformName), mock.patch.object(ps.platform, "machine",
                                                                                   return_value=machine):
            return ps.canExecute(target)

    def test_x64_runs_on_windows_x64_and_arm64_and_arm64_only_on_arm64(self):
        self.assertTrue(self.can("win32", "AMD64", pw.TARGET))
        self.assertTrue(self.can("win32", "ARM64", pw.TARGET))
        self.assertFalse(self.can("win32", "AMD64", pw.ARM64_TARGET))
        self.assertTrue(self.can("win32", "ARM64", pw.ARM64_TARGET))

    def test_no_other_host_runs_a_windows_file(self):
        self.assertFalse(self.can("linux", "x86_64", pw.TARGET))
        self.assertFalse(self.can("darwin", "arm64", pw.ARM64_TARGET))


class ToolTest(unittest.TestCase):
    def test_a_missing_tool_is_named_and_make_must_be_gnu(self):
        with mock.patch.object(ps.shutil, "which", return_value=None):
            with self.assertRaisesRegex(pe.EngineError, "no sh, make, cmake; pass --sh"):
                ps.resolveTools()
        with mock.patch.object(ps.shutil, "which", side_effect=lambda n: "/usr/bin/" + n), \
                mock.patch.object(pe, "run", return_value="bsd make 1\n"):
            with self.assertRaisesRegex(pe.EngineError, "is not GNU make"):
                ps.resolveTools()

    def test_ninja_is_optional(self):
        with mock.patch.object(ps.shutil, "which", side_effect=lambda n: None if n == "ninja" else "/usr/bin/" + n), \
                mock.patch.object(pe, "run", return_value="GNU Make 4.4\n"):
            self.assertNotIn("ninja", ps.resolveTools())

    def test_a_path_that_would_need_quoting_is_refused(self):
        ps.checkPlainPath("/tmp/ok-1.2/x+y", "p")
        with self.assertRaisesRegex(pe.EngineError, "would need quoting"):
            ps.checkPlainPath("/tmp/a b", "p")


class PipelineTest(TempCase):
    """prepareWindowsSourceRuntime with the four builders replaced by fakes that write what upstream installs."""

    def setUp(self):
        super().setUp()
        self.mingw, self.llvm = self.path("mingw"), self.path("llvm")
        for relative in ("COPYING", "COPYING.MinGW-w64/COPYING.MinGW-w64.txt",
                         "COPYING.MinGW-w64-runtime/COPYING.MinGW-w64-runtime.txt", "DISCLAIMER", "DISCLAIMER.PD",
                         "mingw-w64-libraries/winpthreads/COPYING"):
            write(os.path.join(self.mingw, relative), "license " + relative)
        write(os.path.join(self.mingw, "mingw-w64-libraries", "winpthreads", "include", "pthread.h"), "pthread\n")
        write(os.path.join(self.llvm, "compiler-rt", "LICENSE.TXT"), "llvm license")
        self.engine = self.path("engine")
        os.makedirs(self.engine)
        self.skipFile = None
        self.headerClash = False
        self.installedSsp = []
        self.arCommands = []
        for patcher in (mock.patch.object(pr, "engineMajor", return_value=("x86_64-linux", "22.1.1", "22")),
                        mock.patch.object(pe, "run", side_effect=self.fakeAr),
                        mock.patch.object(ps, "engineTool", side_effect=lambda e, n: os.path.join(e, "bin", n)),
                        mock.patch.object(ps, "checkSourceRoot", side_effect=lambda r, rev, w, m: os.path.realpath(r)),
                        mock.patch.object(ps, "checkLlvmVersion"),
                        mock.patch.object(ps, "checkPlainPath", side_effect=lambda path, what: path),
                        mock.patch.object(ps, "buildHeaders", side_effect=self.fakeHeaders),
                        mock.patch.object(ps, "buildCrt", side_effect=self.fakeCrt),
                        mock.patch.object(ps, "buildCompilerRt", side_effect=self.fakeCompilerRt),
                        mock.patch.object(ps, "buildWinpthreads", side_effect=self.fakeWinpthreads),
                        mock.patch.object(ps, "verifySourceConfigs"),
                        mock.patch.object(ps, "toolVersions", return_value={"make": "GNU Make 4.4"})):
            patcher.start()
            self.addCleanup(patcher.stop)

    def fakeAr(self, command):
        self.arCommands.append(command)
        write(command[-1], pr.EMPTY_ARCHIVE)
        return ""

    def fakeHeaders(self, mingw, work, tools, environment):
        include = os.path.join(work, "headers", "include")
        write(os.path.join(include, "_mingw.h"), "mingw\n")
        write(os.path.join(include, "sub", "x.h"), "x\n")
        if self.headerClash:
            write(os.path.join(include, "pthread.h"), "other\n")
        return include

    def fakeCrt(self, mingw, engine, major, headers, target, work, tools, environment, jobs):
        machine = pw.TARGETS[target]["machine"]
        directory = os.path.join(work, target + "-lib")
        os.makedirs(directory)
        for name in ("crt2.o", "dllcrt2.o", "crt2u.o", "crtbegin.o", "crtend.o", "crt1.o"):
            write(os.path.join(directory, name), coff(machine))
        for stem in ("mingw32", "moldname", "mingwex", "msvcrt", "advapi32", "shell32", "user32", "kernel32",
                     "ws2_32", "uuid", "synchronization"):
            write(os.path.join(directory, "lib%s.a" % stem), archive([("m.o", coff(machine)),
                                                                      ("i.o", importMember(machine))]))
        write(os.path.join(directory, "libucrt.def"), "def\n")
        for name in self.installedSsp:
            write(os.path.join(directory, name), archive([("ssp.o", coff(machine))]))
        if self.skipFile:
            os.remove(os.path.join(directory, self.skipFile))
        return directory

    def fakeCompilerRt(self, llvm, engine, major, headers, target, work, tools, environment, jobs):
        path = os.path.join(work, ps.builtinsName(target))
        write(path, archive([("b.o", coff(pw.TARGETS[target]["machine"]))]))
        return path

    def fakeWinpthreads(self, mingw, engine, major, headers, target, work, tools, environment, jobs):
        paths = [os.path.join(work, target + "-pt", n) for n in ("libwinpthread.a", "libpthread.a")]
        for path in paths:
            write(path, archive([("t.o", coff(pw.TARGETS[target]["machine"]))]))
        return paths

    def prepare(self, name="rt", **options):
        out = self.path(name, "windows")
        return out, ps.prepareWindowsSourceRuntime(self.engine, out, self.mingw, "a" * 40, self.llvm, "b" * 40,
                                                   {"sh": "/sh", "make": "/make", "cmake": "/cmake"}, **options)[1]

    def receipt(self, out):
        return json.loads(read(os.path.join(out, "notices", pw.PROVENANCE)))

    def test_path_guard_refusals_stop_before_building_and_clean_the_partial(self):
        for position, label in ((1, "work directory"), (2, "engine")):
            calls = []

            def guard(path, what):
                calls.append((path, what))
                if len(calls) == position:
                    raise pe.EngineError(what + " needs quoting")
                return path

            with mock.patch.object(ps, "checkPlainPath", side_effect=guard):
                with self.assertRaisesRegex(pe.EngineError, label + " needs quoting"):
                    self.prepare()
            self.assertEqual(calls[-1][1], label)
            self.assertEqual(self.arCommands, [])
            self.assertEqual(os.listdir(self.path("rt")), [])

    def test_the_runtime_has_both_targets_two_variants_each_headers_notices_resource_and_a_receipt(self):
        out, records = self.prepare()
        names = sorted(os.listdir(out))
        for target in pw.TARGETS:
            for suffix in ("", ".dll"):
                self.assertIn(target + suffix, names)
                self.assertIn(target + suffix + ".cfg", names)
        self.assertEqual(sorted(n for n in names if "." not in n or n.endswith("-gnu")), [
            "aarch64-windows-gnu", "include", "notices", "resource", "x86_64-windows-gnu"])
        self.assertEqual(len(records), 4)
        for target in pw.TARGETS:
            for suffix in ("", ".dll"):
                files = os.listdir(os.path.join(out, target + suffix))
                for name in ps.REQUIRED_OBJECTS + ["libwinpthread.a", "libpthread.a", "libmsvcrt.a"] + ps.SSP_ARCHIVES:
                    self.assertIn(name, files)
                self.assertNotIn(ps.builtinsName(target), files)
                self.assertNotIn("libucrt.def", files)
        self.assertIn("-shared\n", read(os.path.join(out, "x86_64-windows-gnu.dll.cfg")))
        self.assertIn("-B<CFGDIR>/aarch64-windows-gnu\n", read(os.path.join(out, "aarch64-windows-gnu.cfg")))
        self.assertNotIn(self.dir, read(os.path.join(out, "x86_64-windows-gnu.cfg")))

    def test_both_targets_get_empty_stack_protector_archives_in_every_variant_when_the_install_has_none(self):
        out, _ = self.prepare()
        self.assertEqual(len(self.arCommands), 4)
        receipt = self.receipt(out)
        for variant in receipt["variants"]:
            listed = {f["name"]: f for f in variant["files"]}
            for name in ps.SSP_ARCHIVES:
                path = os.path.join(out, variant["directory"], name)
                with open(path, "rb") as f:
                    self.assertEqual(f.read(), pr.EMPTY_ARCHIVE, msg=path)
                self.assertEqual(listed[name]["sha256"], pe.sha256File(path))
        self.assertIsNone(ps.receiptProblem(receipt, out))
        self.assertTrue(any("libssp.a" in limit and "libmingwex" in limit for limit in receipt["limits"]))

    def test_an_installed_stack_protector_pair_is_carried_unchanged_and_no_archive_is_made(self):
        self.installedSsp = ps.SSP_ARCHIVES
        out, _ = self.prepare()
        self.assertEqual(self.arCommands, [])
        for target in pw.TARGETS:
            for name in ps.SSP_ARCHIVES:
                with open(os.path.join(out, target, name), "rb") as f:
                    members = pr.parseArchive(f.read())
                self.assertEqual([ps.objectMachine(body) for _, body in members], [pw.TARGETS[target]["machine"]])

    def test_a_half_installed_stack_protector_pair_fails_the_preparation_and_leaves_nothing(self):
        self.installedSsp = ["libssp.a"]
        with self.assertRaisesRegex(pe.EngineError, "holds libssp.a but not libssp_nonshared.a"):
            self.prepare()
        self.assertEqual(self.arCommands, [])
        self.assertEqual(os.listdir(self.path("rt")), [])

    def test_the_builtins_are_staged_once_per_target_for_the_bundle_assembly_to_install(self):
        out, _ = self.prepare()
        receipt = self.receipt(out)
        self.assertEqual([(r["target"], r["path"]) for r in receipt["resourceFiles"]], [
            (pw.TARGET, "lib/windows/libclang_rt.builtins-x86_64.a"),
            (pw.ARM64_TARGET, "lib/windows/libclang_rt.builtins-aarch64.a")])
        self.assertEqual(receipt["recipe"]["driverFlags"], ["--rtlib=compiler-rt", "--unwindlib=none"])
        self.assertIsNone(ps.receiptProblem(receipt, out))
        root = self.path("engine", "lib", "clang", "22")
        self.assertEqual(ps.installResource(out, root), [r["path"] for r in receipt["resourceFiles"]])
        self.assertTrue(os.path.isfile(os.path.join(root, "lib", "windows", "libclang_rt.builtins-aarch64.a")))

    def test_builtins_of_the_wrong_machine_fail_the_preparation_and_leave_nothing(self):
        def wrong(llvm, engine, major, headers, target, work, tools, environment, jobs):
            path = os.path.join(work, ps.builtinsName(target))
            write(path, archive([("b.o", coff(pw.MACHINE_AMD64))]))
            return path

        with mock.patch.object(ps, "buildCompilerRt", side_effect=wrong):
            with self.assertRaisesRegex(pe.EngineError, "machine 0x8664, not 0xaa64"):
                self.prepare(targets=[pw.ARM64_TARGET])
        self.assertEqual(os.listdir(self.path("rt")), [])

    def test_the_headers_are_installed_once_with_the_threads_headers_merged(self):
        out, _ = self.prepare()
        self.assertEqual(os.listdir(os.path.join(out, "include", "libc")), ["mingw-w64"])
        include = os.path.join(out, "include", "libc", "mingw-w64")
        self.assertEqual(sorted(os.listdir(include)), ["_mingw.h", "pthread.h", "sub"])
        self.assertIn("-isystem <CFGDIR>/include/libc/mingw-w64\n", read(os.path.join(out, "x86_64-windows-gnu.cfg")))

    def test_a_threads_header_that_mingw_w64_also_installs_is_refused_and_nothing_remains(self):
        self.headerClash = True
        with self.assertRaisesRegex(pe.EngineError, "pthread.h is also in mingw-w64-headers"):
            self.prepare()
        self.assertEqual(os.listdir(self.path("rt")), [])

    def test_the_receipt_names_the_sources_recipe_files_notices_and_limits_and_does_not_certify(self):
        out, _ = self.prepare()
        receipt = self.receipt(out)
        self.assertEqual(receipt["kind"], ps.RECEIPT_KIND)
        self.assertFalse(receipt["redistributionCertified"])
        self.assertEqual(receipt["sources"]["mingw-w64"], {"rev": "a" * 40})
        self.assertEqual(receipt["sources"]["llvm-project"]["rev"], "b" * 40)
        self.assertEqual(receipt["sources"]["llvm-project"]["major"], "22")
        self.assertEqual(receipt["sources"]["llvm-project"]["version"], "22.1.1")
        self.assertEqual(receipt["recipe"]["defaultMsvcrt"], "ucrt")
        self.assertEqual(receipt["recipe"]["winpthreads"], "upstream configure --disable-shared --enable-static; make; make install")
        self.assertEqual(receipt["recipe"]["crtFlags"][pw.ARM64_TARGET],
                         ["--disable-lib32", "--disable-lib64", "--enable-libarm64"])
        self.assertEqual(receipt["crtFilesLeftOut"], {pw.TARGET: ["libucrt.def"], pw.ARM64_TARGET: ["libucrt.def"]})
        self.assertIn("notices/winpthreads/COPYING", receipt["notices"])
        self.assertIn("notices/compiler-rt/LICENSE.TXT", receipt["notices"])
        self.assertEqual(read(os.path.join(out, "notices", "mingw-w64", "COPYING")), "license COPYING")
        self.assertIn("runs no Windows binary", receipt["limits"][0])
        variant = next(v for v in receipt["variants"] if v["target"] == pw.TARGET and v["variant"] == "dll")
        self.assertEqual(variant["startupObject"], "dllcrt2.o")
        self.assertEqual(variant["imageBase"], "0x180000000")
        record = next(f for f in variant["files"] if f["name"] == "dllcrt2.o")
        self.assertEqual(record["sha256"], pe.sha256File(os.path.join(out, "x86_64-windows-gnu.dll", "dllcrt2.o")))

    def test_one_target_can_be_prepared_alone(self):
        out, records = self.prepare(targets=[pw.ARM64_TARGET])
        self.assertEqual({r["target"] for r in records}, {pw.ARM64_TARGET})
        self.assertFalse(os.path.exists(os.path.join(out, "x86_64-windows-gnu")))
        with self.assertRaisesRegex(pe.EngineError, "unknown or duplicated"):
            self.prepare("again", targets=["x86_64-windows-musl"])

    def test_a_missing_startup_object_fails_loud_and_leaves_no_output_or_partial_directory(self):
        self.skipFile = "crt2u.o"
        with self.assertRaisesRegex(pe.EngineError, "lacks crt2u.o"):
            self.prepare()
        self.assertEqual(os.listdir(self.path("rt")), [])

    def test_an_existing_output_is_never_replaced(self):
        os.makedirs(self.path("rt", "windows"))
        with self.assertRaisesRegex(pe.EngineError, "exists; it is never replaced"):
            self.prepare()

    def test_the_build_takes_no_execute_option_and_runs_none_of_the_proofs(self):
        with self.assertRaises(TypeError):
            self.prepare(execute=True)
        ps.buildHeaders.assert_not_called()
        self.prepare("quiet")
        ps.verifySourceConfigs.assert_called_once()
        self.assertEqual(len(ps.verifySourceConfigs.call_args[0]), 4)

    def test_the_command_line_refuses_execute_with_a_build_and_keeps_it_for_prove(self):
        stderr = mock.Mock()
        with mock.patch.object(sys, "stderr", stderr), mock.patch.object(ps, "prepareRuntimeDirectory") as build, \
                mock.patch.object(ps, "resolveTools"):
            with self.assertRaises(SystemExit) as raised:
                ps.main(["--engine", "e", "--output", "o", "--mingw-w64", "m", "--llvm-project", "l", "--execute"])
        self.assertEqual(raised.exception.code, 2)
        build.assert_not_called()
        with mock.patch.object(ps, "prove") as prove:
            self.assertEqual(ps.main(["--prove", "--engine", "e", "--runtime", "r", "--execute", "--deny", "d"]), 0)
        prove.assert_called_once_with("e", "r", ["d"], True)

    def test_a_source_root_that_changes_during_the_build_is_refused(self):
        calls = []

        def check(root, rev, what, markers):
            calls.append(what)
            if len(calls) > 2:
                raise pe.EngineError("%s has uncommitted or untracked files" % what)
            return os.path.realpath(root)

        with mock.patch.object(ps, "checkSourceRoot", side_effect=check):
            with self.assertRaisesRegex(pe.EngineError, "mingw-w64 has uncommitted"):
                self.prepare()
        self.assertEqual(os.listdir(self.path("rt")), [])

    def test_the_receipt_is_checked_against_the_files(self):
        out, _ = self.prepare()
        receipt = self.receipt(out)
        self.assertIsNone(ps.receiptProblem(receipt, out))
        with open(os.path.join(out, "x86_64-windows-gnu", "crt2.o"), "ab") as f:
            f.write(b"x")
        self.assertIn("x86_64-windows-gnu/crt2.o does not match the receipt", ps.receiptProblem(receipt, out))

    def test_a_receipt_of_the_zig_producer_or_another_engine_path_is_refused(self):
        out, _ = self.prepare()
        receipt = self.receipt(out)
        self.assertIn("is not 'source-built-windows-runtime'", ps.receiptProblem(dict(receipt, kind="local-zig-windows-runtime-proof"), out))
        self.assertIn("engineRelative", ps.receiptProblem(dict(receipt, engineRelative="../engine"), out))
        self.assertIn("are not in", ps.receiptProblem(dict(receipt, targets=["x86_64-linux-gnu"]), out))


if __name__ == "__main__":
    unittest.main()
