import ast
import hashlib
import io
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import prepareEngine as pe

HAS_CLANG = sys.platform == "darwin" and os.path.exists("/usr/bin/clang")


def write(path, text, mode=None):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    if mode:
        os.chmod(path, mode)


def read(path):
    with open(path) as f:
        return f.read()


def writeScript(path, output):
    write(path, "#!/bin/sh\necho '%s'\n" % output, 0o755)


class TempCase(unittest.TestCase):
    def setUp(self):
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="prepareEngineTest-"))
        self.addCleanup(shutil.rmtree, self.dir)

    def path(self, *parts):
        return os.path.join(self.dir, *parts)

    def textBundle(self):
        root = self.path("bundle")
        write(os.path.join(root, "bin", "tool"), "tool\n")
        write(os.path.join(root, "notices", "a.txt"), "notice\n")
        os.symlink("tool", os.path.join(root, "bin", "alias"))
        pe.writeContract(root, "aarch64-macos", "22.1.1")
        return root


class ContractTest(TempCase):
    def test_files_sha256_is_canonical(self):
        root = self.textBundle()
        with open(os.path.join(root, "FILES.sha256"), "rb") as f:
            raw = f.read()
        tool = hashlib.sha256(b"tool\n").hexdigest()
        lines = raw.decode("utf-8").splitlines(keepends=True)
        self.assertEqual([l.split("  ", 1)[1] for l in lines],
                         ["HOST\n", "VERSION\n", "bin/alias\n", "bin/tool\n", "notices/a.txt\n"])
        self.assertIn("%s  bin/alias\n" % tool, lines)
        self.assertEqual(read(os.path.join(root, "IDENTITY")), hashlib.sha256(raw).hexdigest() + "\n")
        self.assertEqual(read(os.path.join(root, "HOST")), "aarch64-macos\n")
        self.assertEqual(pe.verifyContract(root), ("aarch64-macos", "22.1.1"))

    def test_changed_file_is_rejected(self):
        root = self.textBundle()
        write(os.path.join(root, "notices", "a.txt"), "other\n")
        with self.assertRaisesRegex(pe.EngineError, "hash mismatch: notices/a.txt"):
            pe.verifyContract(root)

    def test_extra_and_missing_files_are_rejected(self):
        root = self.textBundle()
        write(os.path.join(root, "extra"), "x")
        with self.assertRaisesRegex(pe.EngineError, "extra"):
            pe.verifyContract(root)
        os.remove(os.path.join(root, "extra"))
        os.remove(os.path.join(root, "notices", "a.txt"))
        with self.assertRaisesRegex(pe.EngineError, "notices/a.txt"):
            pe.verifyContract(root)

    def test_identity_must_match_files_hash(self):
        root = self.textBundle()
        write(os.path.join(root, "IDENTITY"), "0" * 64 + "\n")
        with self.assertRaisesRegex(pe.EngineError, "IDENTITY"):
            pe.verifyContract(root)

    def test_host_and_version_are_one_fixed_line(self):
        for name, text in (("HOST", "riscv-macos\n"), ("HOST", "aarch64-macos"),
                           ("VERSION", "22.1\n"), ("VERSION", "22.1.1\nextra\n")):
            root = self.textBundle()
            write(os.path.join(root, name), text)
            with self.assertRaises(pe.EngineError, msg=repr(text)):
                pe.verifyContract(root)
            shutil.rmtree(root)

    def test_unsafe_and_unsorted_listings_are_rejected(self):
        root = self.textBundle()
        digest = hashlib.sha256(b"x").hexdigest()
        for lines in ("%s  ../escape\n" % digest, "%s  /abs\n" % digest,
                      "%s  a/./b\n" % digest, "%s  a\\b\n" % digest):
            write(os.path.join(root, "FILES.sha256"), lines)
            with self.assertRaisesRegex(pe.EngineError, "unsafe path"):
                pe.verifyContract(root)
        with open(os.path.join(root, "HOST"), "rb") as f:
            host = hashlib.sha256(f.read()).hexdigest()
        write(os.path.join(root, "FILES.sha256"), "%s  b\n%s  a\n" % (host, host))
        with self.assertRaisesRegex(pe.EngineError, "sorted"):
            pe.verifyContract(root)
        write(os.path.join(root, "FILES.sha256"), "%s  HOST\n" % host.upper())
        with self.assertRaisesRegex(pe.EngineError, "bad line"):
            pe.verifyContract(root)

    def test_symlink_leaving_the_bundle_is_rejected(self):
        root = self.textBundle()
        write(self.path("outside"), "secret")
        os.symlink(self.path("outside"), os.path.join(root, "bin", "escape"))
        with self.assertRaisesRegex(pe.EngineError, "leaves the bundle"):
            pe.listFiles(root)

    def test_directory_symlink_and_dangling_symlink_are_rejected(self):
        root = self.textBundle()
        os.symlink("notices", os.path.join(root, "linkdir"))
        with self.assertRaisesRegex(pe.EngineError, "directory symlink"):
            pe.listFiles(root)
        os.remove(os.path.join(root, "linkdir"))
        os.symlink("missing", os.path.join(root, "bin", "dangling"))
        with self.assertRaisesRegex(pe.EngineError, "leaves the bundle or is not a file"):
            pe.listFiles(root)

    def test_newline_in_path_is_rejected(self):
        root = self.textBundle()
        write(os.path.join(root, "bad\nname"), "x")
        with self.assertRaisesRegex(pe.EngineError, "unsupported character"):
            pe.listFiles(root)


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


class LinkLikeTest(TempCase):
    def test_a_plain_file_and_directory_are_not_link_like(self):
        write(self.path("d", "f"), "x")
        self.assertEqual((pe.isLinkLike(self.path("d")), pe.isLinkLike(self.path("d", "f"))), (False, False))

    def test_a_symlink_to_a_file_or_a_directory_is_link_like(self):
        write(self.path("d", "f"), "x")
        os.symlink(self.path("d"), self.path("dir link"))
        os.symlink(self.path("d", "f"), self.path("file link"))
        self.assertEqual((pe.isLinkLike(self.path("dir link")), pe.isLinkLike(self.path("file link"))), (True, True))

    def test_a_reparse_point_is_link_like_even_when_islink_is_false(self):
        os.makedirs(self.path("junction"))
        with reparse(self.path("junction")), mock.patch.object(os.path, "islink", return_value=False):
            self.assertTrue(pe.isLinkLike(self.path("junction")))

    def test_directory_attributes_without_the_reparse_bit_are_not_link_like(self):
        os.makedirs(self.path("d"))
        attributes = stat.FILE_ATTRIBUTE_DIRECTORY | stat.FILE_ATTRIBUTE_ARCHIVE
        real = os.lstat

        class Plain:
            st_file_attributes = attributes

            def __init__(self, inner):
                self.inner = inner

            def __getattr__(self, name):
                return getattr(self.inner, name)

        with mock.patch.object(os, "lstat", side_effect=lambda p, *a, **k: Plain(real(p, *a, **k))):
            self.assertFalse(pe.isLinkLike(self.path("d")))

    def test_list_files_refuses_a_directory_that_is_a_reparse_point_and_reads_no_data_behind_it(self):
        write(self.path("outside", "data"), "secret")
        write(self.path("bundle", "bin", "tool"), "tool")
        os.symlink(self.path("outside"), self.path("bundle", "dir"))
        with reparse(self.path("bundle", "dir")), mock.patch.object(os.path, "islink", return_value=False):
            with self.assertRaisesRegex(pe.EngineError, "directory symlink .*dir"):
                pe.listFiles(self.path("bundle"))

    def test_list_files_refuses_a_real_directory_carrying_the_reparse_attribute(self):
        write(self.path("bundle", "junction", "data"), "x")
        with reparse(self.path("bundle", "junction")):
            with self.assertRaisesRegex(pe.EngineError, "directory symlink .*junction"):
                pe.listFiles(self.path("bundle"))

    def test_list_files_still_refuses_a_symlinked_directory_and_still_accepts_an_inside_file_alias(self):
        write(self.path("bundle", "bin", "tool"), "tool")
        os.symlink("tool", self.path("bundle", "bin", "alias"))
        self.assertEqual(pe.listFiles(self.path("bundle")), ["bin/alias", "bin/tool"])
        os.symlink(self.path("bundle", "bin"), self.path("bundle", "linked"))
        with self.assertRaisesRegex(pe.EngineError, "directory symlink"):
            pe.listFiles(self.path("bundle"))


class WindowsHostContractTest(TempCase):
    def bundle(self, host="x86_64-windows"):
        root = self.path("bundle")
        write(os.path.join(root, "bin", "clang.exe"), "exe\n")
        write(os.path.join(root, "lib", "clang", "22", "include", "stddef.h"), "h\n")
        pe.writeContract(root, host, "22.1.1")
        return root

    def windowsSeparator(self):
        """Patches that make listFiles see the paths a native Windows os.path.relpath returns: backslash separated."""
        relpath = os.path.relpath
        return (mock.patch.object(pe.os, "sep", "\\"),
                mock.patch.object(pe.os.path, "relpath", side_effect=lambda p, s: relpath(p, s).replace("/", "\\")))

    def test_a_windows_x64_host_is_a_contract_host_and_the_other_hosts_still_are(self):
        self.assertEqual(pe.WINDOWS_X64, "x86_64-windows")
        self.assertEqual(pe.verifyContract(self.bundle()), ("x86_64-windows", "22.1.1"))
        self.assertEqual(pe.KNOWN_HOSTS, ("aarch64-macos", "x86_64-macos", "x86_64-linux", "x86_64-windows"))

    def test_native_windows_separators_become_slashes_before_the_contract_validates_and_sorts(self):
        root = self.bundle()
        expected = pe.listFiles(root)
        with open(os.path.join(root, "FILES.sha256"), "rb") as f:
            manifest = f.read()
        first, second = self.windowsSeparator()
        with first, second:
            self.assertEqual(pe.listFiles(root), expected)
            pe.writeContract(root, "x86_64-windows", "22.1.1")
            self.assertEqual(pe.verifyContract(root), ("x86_64-windows", "22.1.1"))
        with open(os.path.join(root, "FILES.sha256"), "rb") as f:
            self.assertEqual(f.read(), manifest)
        self.assertIn("bin/clang.exe", expected)
        self.assertIn("lib/clang/22/include/stddef.h", expected)

    def test_list_files_reads_native_windows_paths_as_the_slash_paths_the_manifest_holds(self):
        root = self.bundle("x86_64-linux")
        expected = pe.listFiles(root)
        first, second = self.windowsSeparator()
        with first, second:
            self.assertEqual(pe.listFiles(root), expected)
        self.assertEqual(expected, ["HOST", "VERSION", "bin/clang.exe", "lib/clang/22/include/stddef.h"])

    def test_a_backslash_that_is_part_of_a_posix_file_name_is_still_refused(self):
        root = self.path("bundle")
        write(os.path.join(root, "bin", "a\\b.exe"), "x\n")
        with self.assertRaisesRegex(pe.EngineError, "unsupported character in path"):
            pe.listFiles(root)

    def test_a_backslash_in_a_manifest_path_is_still_refused_on_every_host(self):
        root = self.bundle()
        with open(os.path.join(root, "FILES.sha256"), "a", encoding="utf-8") as f:
            f.write("%s  bin\\clang.exe\n" % ("0" * 64))
        first, second = self.windowsSeparator()
        with first, second:
            with self.assertRaisesRegex(pe.EngineError, "unsafe path"):
                pe.verifyContract(root)

    def test_verify_engine_hands_a_windows_bundle_to_the_windows_module_and_never_reads_mach_o_or_elf(self):
        root = self.bundle()
        module, other = mock.Mock(**{"verifyEngine.return_value": 12}), mock.Mock()
        with mock.patch.dict(sys.modules, {"prepareWindowsEngine": module, "prepareLinuxEngine": other}), \
                mock.patch.object(pe, "verifyLayout", side_effect=AssertionError("mac layout")), \
                mock.patch.object(pe, "auditLoadCommands", side_effect=AssertionError("mach-o audit")):
            self.assertEqual(pe.verifyEngine(root), ("x86_64-windows", "22.1.1", 12))
            self.assertEqual(pe.verifyEngine(root, "/x/llvm-readobj.exe"), ("x86_64-windows", "22.1.1", 12))
        self.assertEqual([c.args for c in module.verifyEngine.call_args_list], [
            (root, "x86_64-windows", "22.1.1", None), (root, "x86_64-windows", "22.1.1", "/x/llvm-readobj.exe")])
        other.verifyEngine.assert_not_called()

    def test_the_verify_command_names_the_binary_kind_of_a_windows_bundle(self):
        with mock.patch.object(pe, "verifyEngine", return_value=("x86_64-windows", "22.1.1", 13)) as verify, \
                mock.patch("sys.stdout", new_callable=io.StringIO) as out:
            self.assertEqual(pe.main(["--verify", self.bundle(), "--inspector", "/x/llvm-readobj"]), 0)
        self.assertEqual(out.getvalue(), "verified host=x86_64-windows version=22.1.1 pe=13\n")


class LinuxHostContractTest(TempCase):
    def linuxBundle(self, host="x86_64-linux"):
        root = self.path("bundle")
        write(os.path.join(root, "bin", "tool"), "tool\n")
        pe.writeContract(root, host, "21.1.8")
        return root

    def test_a_linux_x64_host_is_a_contract_host_and_the_mac_hosts_still_are(self):
        self.assertEqual(pe.LINUX_X64, "x86_64-linux")
        self.assertEqual(pe.verifyContract(self.linuxBundle()), ("x86_64-linux", "21.1.8"))
        for host in ("aarch64-macos", "x86_64-macos"):
            root = self.path(host)
            write(os.path.join(root, "bin", "tool"), "tool\n")
            pe.writeContract(root, host, "22.1.1")
            self.assertEqual(pe.verifyContract(root), (host, "22.1.1"))

    def test_other_hosts_are_still_refused(self):
        for host in ("aarch64-linux", "aarch64-windows", "x86_64-windows-gnu", "x86_64-linux-gnu", "windows", "linux"):
            shutil.rmtree(self.path("bundle"), ignore_errors=True)
            with self.assertRaisesRegex(pe.EngineError, "HOST is not one line matching"):
                pe.verifyContract(self.linuxBundle(host))

    def test_verify_engine_hands_a_linux_bundle_to_the_linux_module_and_never_reads_mach_o(self):
        root = self.linuxBundle()
        module = mock.Mock(**{"verifyEngine.return_value": 7})
        with mock.patch.dict(sys.modules, {"prepareLinuxEngine": module}), \
                mock.patch.object(pe, "verifyLayout", side_effect=AssertionError("mac layout")), \
                mock.patch.object(pe, "auditLoadCommands", side_effect=AssertionError("mach-o audit")):
            self.assertEqual(pe.verifyEngine(root, "/x/llvm-readobj"), ("x86_64-linux", "21.1.8", 7))
        module.verifyEngine.assert_called_once_with(root, "x86_64-linux", "21.1.8", "/x/llvm-readobj")

    def test_verify_engine_keeps_the_mac_layout_and_load_command_audit_for_mac_hosts(self):
        root = self.path("mac")
        write(os.path.join(root, "bin", "tool"), "tool\n")
        pe.writeContract(root, "aarch64-macos", "22.1.1")
        module = mock.Mock()
        with mock.patch.dict(sys.modules, {"prepareLinuxEngine": module}), \
                mock.patch.object(pe, "verifyLayout") as layout, mock.patch.object(pe, "auditLoadCommands", return_value=3):
            self.assertEqual(pe.verifyEngine(root), ("aarch64-macos", "22.1.1", 3))
            self.assertEqual(pe.verifyEngine(root, "/ignored/llvm-readobj"), ("aarch64-macos", "22.1.1", 3))
        layout.assert_called_with(root, "22.1.1")
        module.verifyEngine.assert_not_called()

    def test_the_verify_command_names_the_binary_kind_of_the_host(self):
        root = self.linuxBundle()
        for host, count, label in (("x86_64-linux", 4, "elf=4"), ("aarch64-macos", 5, "macho=5")):
            with mock.patch.object(pe, "verifyEngine", return_value=(host, "1.2.3", count)) as verify, \
                    mock.patch("sys.stdout", new_callable=io.StringIO) as out:
                self.assertEqual(pe.main(["--verify", root, "--inspector", "/x/llvm-readobj"]), 0)
            self.assertEqual(out.getvalue(), "verified host=%s version=1.2.3 %s\n" % (host, label))
            verify.assert_called_with(root, "/x/llvm-readobj")

    def test_every_producer_and_prover_calls_verify_engine_with_the_engine_root_alone(self):
        directory = os.path.dirname(os.path.abspath(__file__))
        calls = {}
        for name in ("prepareRuntime", "prepareCppRuntime", "prepareWindowsRuntime", "prepareBundle", "proveCompiler"):
            with open(os.path.join(directory, name + ".py"), encoding="utf-8") as f:
                tree = ast.parse(f.read())
            calls[name] = [(len(n.args), len(n.keywords)) for n in ast.walk(tree) if isinstance(n, ast.Call)
                           and isinstance(n.func, ast.Attribute) and n.func.attr == "verifyEngine"]
        self.assertEqual({k: len(v) for k, v in calls.items()}, {"prepareRuntime": 2, "prepareCppRuntime": 1, "prepareWindowsRuntime": 1,
                                                                  "prepareBundle": 4, "proveCompiler": 1})
        self.assertEqual({pair for v in calls.values() for pair in v}, {(1, 0)})

    def test_the_source_path_scan_takes_the_binary_test_of_the_host(self):
        root = self.path("scan")
        write(os.path.join(root, "a"), "xx/src/yy")
        write(os.path.join(root, "b"), "/src/")
        self.assertEqual(pe.sourcePathLiterals(root, ["/src/"], lambda path: os.path.basename(path) == "a"), {"a": 1})
        self.assertEqual(pe.sourcePathLiterals(root, ["/src/"]), {})


class ContainsPathTest(TempCase):
    def caseInsensitive(self):
        os.makedirs(self.path("Probe"))
        return os.path.exists(self.path("probe"))

    def test_a_path_under_a_symlink_alias_of_the_parent_is_contained(self):
        os.makedirs(self.path("real"))
        os.symlink(self.path("real"), self.path("alias"))
        self.assertNotEqual(os.path.commonpath([self.path("real"), self.path("alias", "out")]), self.path("real"))
        self.assertTrue(pe.containsPath(self.path("real"), self.path("alias", "out")))
        self.assertTrue(pe.containsPath(self.path("real"), self.path("alias", "deep", "er", "out")))
        self.assertTrue(pe.containsPath(self.path("alias"), self.path("real", "out")))

    def test_a_chain_of_aliases_is_followed_to_the_directory_it_names(self):
        os.makedirs(self.path("real", "inner"))
        os.symlink(self.path("real"), self.path("first"))
        os.symlink(self.path("first"), self.path("second"))
        self.assertTrue(pe.containsPath(self.path("real", "inner"), self.path("second", "inner", "out")))
        self.assertFalse(pe.containsPath(self.path("real", "inner"), self.path("second", "other", "out")))

    def test_a_path_that_does_not_exist_yet_is_judged_by_its_existing_prefix(self):
        os.makedirs(self.path("real"))
        os.symlink(self.path("real"), self.path("alias"))
        self.assertTrue(pe.containsPath(self.path("real"), self.path("alias", "not", "yet", "there")))
        self.assertFalse(pe.containsPath(self.path("real"), self.path("nowhere", "not", "yet")))

    def test_the_same_directory_is_contained_and_a_neighbour_or_an_ancestor_is_not(self):
        os.makedirs(self.path("bundle", "inner"))
        os.makedirs(self.path("bundle-two"))
        self.assertTrue(pe.containsPath(self.path("bundle"), self.path("bundle")))
        self.assertFalse(pe.containsPath(self.path("bundle"), self.path("bundle-two", "out")))
        self.assertFalse(pe.containsPath(self.path("bundle", "inner"), self.path("bundle")))

    def test_a_link_leading_out_of_the_parent_is_not_contained(self):
        os.makedirs(self.path("bundle"))
        os.makedirs(self.path("elsewhere"))
        os.symlink(self.path("elsewhere"), self.path("bundle", "escape"))
        self.assertFalse(pe.containsPath(self.path("bundle"), self.path("bundle", "escape", "out")))

    def test_a_relative_path_is_judged_where_it_points(self):
        os.makedirs(self.path("bundle"))
        before = os.getcwd()
        self.addCleanup(os.chdir, before)
        os.chdir(self.dir)
        self.assertTrue(pe.containsPath(self.path("bundle"), os.path.join("bundle", "out")))
        self.assertFalse(pe.containsPath(self.path("bundle"), "other"))

    def test_a_parent_that_does_not_exist_is_compared_by_resolved_name(self):
        self.assertTrue(pe.containsPath(self.path("gone"), self.path("gone", "out")))
        self.assertFalse(pe.containsPath(self.path("gone"), self.path("other", "out")))

    def test_another_spelling_of_the_same_directory_is_the_same_directory(self):
        if not self.caseInsensitive():
            self.skipTest("this volume tells names apart by case")
        os.makedirs(self.path("Bundle"))
        self.assertNotEqual(os.path.realpath(self.path("bundle")), os.path.realpath(self.path("Bundle")))
        self.assertTrue(pe.containsPath(self.path("Bundle"), self.path("bundle", "out")))
        self.assertTrue(pe.containsPath(self.path("bundle"), self.path("Bundle", "inner", "out")))
        self.assertFalse(pe.containsPath(self.path("Bundle"), self.path("Other", "out")))


class SourceRootTest(TempCase):
    def fakeRoots(self, lldVersion="22.1.1", resource=True):
        llvm, lld = self.path("llvm"), self.path("lld")
        shutil.rmtree(llvm, ignore_errors=True)
        shutil.rmtree(lld, ignore_errors=True)
        writeScript(os.path.join(llvm, "bin", "clang"), "clang version 22.1.1")
        writeScript(os.path.join(lld, "bin", "ld64.lld"), "Homebrew LLD " + lldVersion)
        if resource:
            write(os.path.join(llvm, "lib", "clang", "22", "include", "stddef.h"), "")
        return llvm, lld

    def prepare(self, llvm, lld, output=None):
        return pe.prepareEngine(llvm, lld, output or self.path("out", "engine"))

    @mock.patch.object(pe, "detectHost", return_value=("aarch64-macos", 0x0100000C))
    def test_failures_leave_no_output(self, _):
        llvm, lld = self.fakeRoots(lldVersion="21.1.0")
        with self.assertRaisesRegex(pe.EngineError, "does not match clang"):
            self.prepare(llvm, lld)
        llvm, lld = self.fakeRoots(resource=False)
        with self.assertRaisesRegex(pe.EngineError, "missing resource directory"):
            self.prepare(llvm, lld)
        with self.assertRaisesRegex(pe.EngineError, "missing source file"):
            self.prepare(*self.fakeRoots())
        self.assertFalse(os.path.lexists(self.path("out")))

    @mock.patch.object(pe, "detectHost", return_value=("aarch64-macos", 0x0100000C))
    def test_missing_root_is_rejected(self, _):
        with self.assertRaisesRegex(pe.EngineError, "not a directory"):
            self.prepare(self.path("nope"), self.path("nope2"))

    @mock.patch.object(pe, "detectHost", return_value=("aarch64-macos", 0x0100000C))
    def test_existing_output_is_never_replaced(self, _):
        llvm, lld = self.fakeRoots()
        for kind in ("dir", "file", "link"):
            output = self.path("existing-" + kind)
            if kind == "dir":
                write(os.path.join(output, "keep"), "keep")
            elif kind == "file":
                write(output, "keep")
            else:
                os.symlink(self.path("llvm"), output)
            with self.assertRaisesRegex(pe.EngineError, "never replaced"):
                self.prepare(llvm, lld, output)
        self.assertEqual(read(self.path("existing-dir", "keep")), "keep")
        self.assertEqual(read(self.path("existing-file")), "keep")

    @mock.patch.object(pe, "detectHost", return_value=("aarch64-macos", 0x0100000C))
    def test_output_inside_source_root_is_rejected(self, _):
        llvm, lld = self.fakeRoots()
        with self.assertRaisesRegex(pe.EngineError, "inside a source root"):
            self.prepare(llvm, lld, os.path.join(llvm, "engine"))

    @mock.patch.object(pe, "detectHost", return_value=("aarch64-macos", 0x0100000C))
    def test_output_reached_through_an_alias_into_a_source_root_is_rejected(self, _):
        llvm, lld = self.fakeRoots()
        os.symlink(llvm, self.path("alias"))
        for output in (os.path.join(self.path("alias"), "engine"), os.path.join(self.path("alias"), "a", "engine")):
            with self.assertRaisesRegex(pe.EngineError, "inside a source root"):
                self.prepare(llvm, lld, output)
        self.assertEqual(sorted(os.listdir(llvm)), ["bin", "lib"])

    def test_unsupported_hosts_fail_loud(self):
        with mock.patch.object(pe.sys, "platform", "linux"):
            with self.assertRaisesRegex(pe.EngineError, "unsupported host"):
                pe.detectHost()
        with mock.patch.object(pe.sys, "platform", "darwin"), \
                mock.patch.object(pe.platform, "machine", return_value="ppc64"):
            with self.assertRaisesRegex(pe.EngineError, "unsupported macOS machine"):
                pe.detectHost()


@unittest.skipUnless(HAS_CLANG, "needs macOS and /usr/bin/clang")
class MachOTest(TempCase):
    def build(self):
        foreign = self.path("foreign")
        os.makedirs(foreign)
        write(os.path.join(foreign, "dep.c"), "int dep(void){return 7;}\n")
        write(os.path.join(foreign, "main.c"),
              "int dep(void);\nint main(void){return dep()==7?0:1;}\n")
        pad = "-Wl,-headerpad_max_install_names"
        dylib = os.path.join(foreign, "libdep.dylib")
        subprocess.check_call(["/usr/bin/clang", "-dynamiclib", pad, "-install_name", dylib,
                               os.path.join(foreign, "dep.c"), "-o", dylib])
        tool = os.path.join(foreign, "tool")
        subprocess.check_call(["/usr/bin/clang", pad, os.path.join(foreign, "main.c"),
                               dylib, "-o", tool])
        return foreign, tool, dylib

    def bundle(self, tool, dylib):
        root = self.path("bundle")
        for rel, source in (("bin/tool", tool), ("lib/libdep.dylib", dylib)):
            os.makedirs(os.path.dirname(os.path.join(root, rel)), exist_ok=True)
            shutil.copyfile(source, os.path.join(root, rel))
            os.chmod(os.path.join(root, rel), 0o755)
        return root

    def test_closure_rewrite_audit_and_relocation(self):
        foreign, tool, dylib = self.build()
        _, cpu = pe.detectHost()
        plan = pe.planClosure({"bin/tool": tool}, cpu)
        self.assertEqual(plan, {"bin/tool": tool, "lib/libdep.dylib": os.path.realpath(dylib)})
        root = self.bundle(tool, dylib)
        with self.assertRaisesRegex(pe.EngineError, "install name|external loader"):
            pe.auditLoadCommands(root)
        for rel in sorted(plan):
            pe.rewriteLoadCommands(os.path.join(root, rel), root)
        self.assertEqual(pe.auditLoadCommands(root), 2)
        _, deps, rpaths = pe.loadCommands(os.path.join(root, "bin", "tool"))
        self.assertIn("@rpath/libdep.dylib", deps)
        self.assertEqual(rpaths, ["@loader_path/../lib"])
        moved = self.path("moved")
        shutil.copytree(root, moved)
        shutil.rmtree(root)
        shutil.rmtree(foreign)
        self.assertEqual(subprocess.call([os.path.join(moved, "bin", "tool")]), 0)

    def test_audit_rejects_unresolved_rpath_dependency(self):
        foreign, tool, dylib = self.build()
        root = self.bundle(tool, dylib)
        for rel in ("bin/tool", "lib/libdep.dylib"):
            pe.rewriteLoadCommands(os.path.join(root, rel), root)
        os.remove(os.path.join(root, "lib", "libdep.dylib"))
        with self.assertRaisesRegex(pe.EngineError, "does not resolve inside the bundle"):
            pe.auditLoadCommands(root)

    def test_absolute_rpath_is_rejected(self):
        foreign, tool, dylib = self.build()
        root = self.bundle(tool, dylib)
        for rel in ("bin/tool", "lib/libdep.dylib"):
            pe.rewriteLoadCommands(os.path.join(root, rel), root)
        subprocess.check_call(["/usr/bin/install_name_tool", "-add_rpath", "/opt/elsewhere",
                               os.path.join(root, "bin", "tool")])
        with self.assertRaisesRegex(pe.EngineError, "not bundle-relative"):
            pe.auditLoadCommands(root)

    def test_unresolvable_dependency_fails_closure(self):
        foreign, tool, dylib = self.build()
        os.remove(dylib)
        _, cpu = pe.detectHost()
        with self.assertRaisesRegex(pe.EngineError, "cannot resolve dependency"):
            pe.planClosure({"bin/tool": tool}, cpu)

    def test_dependency_without_license_fails(self):
        foreign, tool, dylib = self.build()
        plan = {"bin/tool": tool, "lib/libdep.dylib": os.path.realpath(dylib)}
        with self.assertRaisesRegex(pe.EngineError, "no license file"):
            pe.collectPackages(plan, [])
        write(os.path.join(foreign, "LICENSE"), "terms")
        records = pe.collectPackages(plan, [])
        self.assertEqual([r["licenses"] for r in records], [["LICENSE"]])

    def test_host_slice_is_required(self):
        foreign, tool, dylib = self.build()
        _, cpu = pe.detectHost()
        other = 0x01000007 if cpu == 0x0100000C else 0x0100000C
        with self.assertRaisesRegex(pe.EngineError, "no slice for this host"):
            pe.planClosure({"bin/tool": tool}, other)


if __name__ == "__main__":
    unittest.main()
