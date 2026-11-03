import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

import prepareEngine as pe
import prepareNotices as pn

HERE = os.path.dirname(os.path.abspath(__file__))
LLVM_TEXT = "Apache License v2.0 with LLVM Exceptions\n"


def write(path, text="x\n"):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)


def receipt(path, **fields):
    write(path, json.dumps(fields))


class BundleCase(unittest.TestCase):
    def setUp(self):
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="prepareNoticesTest-"))
        self.addCleanup(shutil.rmtree, self.root)
        self.make()

    def path(self, *parts):
        return os.path.join(self.root, *parts)

    def make(self):
        shutil.rmtree(self.root)
        os.makedirs(self.root)
        write(self.path("notices/llvm@22/LICENSE.TXT"), LLVM_TEXT)
        write(self.path("notices/llvm@22/sbom.spdx.json"))
        write(self.path("notices/zstd/COPYING"))
        receipt(self.path("notices/provenance.json"), kind="local-homebrew-proof", packages=[
            {"name": "llvm@22", "role": "llvm", "licenses": ["notices/llvm@22/LICENSE.TXT"], "sbom": "notices/llvm@22/sbom.spdx.json"},
            {"name": "zstd", "role": "dependency", "licenses": ["notices/zstd/COPYING"], "sbom": None}])
        write(self.path("notices/compiler-rt/LICENSE.TXT"), LLVM_TEXT)
        receipt(self.path("notices/sanitizer-provenance.json"), kind="local-source-sanitizer-runtime",
                source={"compilerRtLicenseSha256": pe.sha256File(self.path("notices/compiler-rt/LICENSE.TXT"))})
        receipt(self.path("notices/bundle-provenance.json"), kind="local-bundle-assembly")
        write(self.path("runtime/notices/zig/LICENSE"), "The MIT License (Expat)\n")
        write(self.path("runtime/notices/glibc/LICENSES"), "GNU Lesser General Public License\n")
        write(self.path("runtime/notices/musl/COPYRIGHT"), "standard MIT license\n")
        write(self.path("runtime/notices/wasi-libc/LICENSE"))
        receipt(self.path("runtime/notices/runtime-provenance.json"), kind="local-zig-runtime-proof", zig={"version": "0.16.0"},
                noticeGaps=["no license for the Linux uapi headers"], targets=[
                    {"target": "wasm32-wasi", "notices": ["notices/wasi-libc/LICENSE", "notices/musl/COPYRIGHT", "notices/zig/LICENSE"]},
                    {"target": "x86_64-linux-gnu.2.31", "notices": []},
                    {"target": "x86_64-linux-musl", "notices": []}])
        for name in ("libcxx", "libcxxabi", "libunwind"):
            write(self.path("runtime/notices", name, "LICENSE.TXT"), LLVM_TEXT)
        receipt(self.path("runtime/notices/cpp-provenance.json"), kind="local-zig-cpp-runtime-proof", zig={"version": "0.16.0"},
                notices=["notices/%s/LICENSE.TXT" % n for n in ("libcxx", "libcxxabi", "libunwind")])
        write(self.path("runtime/windows/notices/mingw-w64/COPYING"))
        write(self.path("runtime/windows/notices/zig/LICENSE"), "The MIT License (Expat)\n")
        receipt(self.path("runtime/windows/notices/windows-provenance.json"), kind="local-zig-windows-runtime-proof",
                zig={"version": "0.16.0"}, targets=["x86_64-windows-gnu"], notices=["notices/mingw-w64/COPYING", "notices/zig/LICENSE"])
        write(self.path("runtime/darwin/notices/zig/LICENSE"), "The MIT License (Expat)\n")
        receipt(self.path("runtime/darwin/notices/darwin-provenance.json"), kind="local-zig-darwin-runtime-proof",
                zig={"version": "0.16.0"}, targets=["aarch64-macos"], notices=["notices/zig/LICENSE"])

    def run_cli(self):
        done = subprocess.run([sys.executable, os.path.join(HERE, "prepareNotices.py"), self.root],
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
        return done.returncode, done.stdout + done.stderr


class MatchTest(BundleCase):
    def test_a_bundle_whose_receipts_and_notices_agree_passes_and_reports_the_gaps_it_records(self):
        rc, output = self.run_cli()
        self.assertEqual(rc, 0, output)
        self.assertIn("recorded notice gap: runtime/notices/runtime-provenance.json: no license for the Linux uapi headers", output)

    def test_the_prover_runs_inside_prepareEngine_verify_after_the_bundle_layout(self):
        with open(os.path.join(HERE, "prepareEngine.py")) as f:
            self.assertIn("prepareNotices.report(args.verify)", f.read())


class MissingNoticeTest(BundleCase):
    def assertRefused(self, fragment):
        rc, output = self.run_cli()
        self.assertEqual(rc, 1, output)
        self.assertIn(fragment, output)

    def test_every_component_class_needs_its_own_license_file(self):
        for relative, component in (("notices/llvm@22/LICENSE.TXT", "llvm@22"), ("notices/zstd/COPYING", "zstd"),
                                    ("notices/compiler-rt/LICENSE.TXT", "compiler-rt"),
                                    ("runtime/notices/glibc/LICENSES", "glibc"), ("runtime/notices/musl/COPYRIGHT", "musl"),
                                    ("runtime/notices/wasi-libc/LICENSE", "wasi-libc"),
                                    ("runtime/notices/libunwind/LICENSE.TXT", "libunwind"),
                                    ("runtime/notices/zig/LICENSE", "zig"),
                                    ("runtime/windows/notices/mingw-w64/COPYING", "mingw-w64")):
            with self.subTest(relative):
                self.make()
                os.remove(self.path(relative))
                self.assertRefused("%s: %s is missing or empty" % (component, relative))

    def test_a_libc_the_targets_link_needs_its_notice_even_when_the_receipt_declares_none(self):
        os.remove(self.path("runtime/notices/glibc/LICENSES"))
        receipt(self.path("runtime/notices/runtime-provenance.json"), kind="local-zig-runtime-proof",
                zig={"version": "0.16.0"}, targets=[{"target": "aarch64-linux-gnu.2.31", "notices": []}])
        self.assertRefused("glibc: runtime/notices/glibc/LICENSES is missing")

    def test_an_empty_license_or_one_without_its_words_or_hash_is_refused(self):
        write(self.path("runtime/notices/zig/LICENSE"), "")
        self.assertRefused("zig: runtime/notices/zig/LICENSE is missing or empty")
        write(self.path("runtime/notices/zig/LICENSE"), "something else\n")
        self.assertRefused("does not contain 'MIT License'")
        self.make()
        write(self.path("notices/compiler-rt/LICENSE.TXT"), LLVM_TEXT + "edited\n")
        self.assertRefused("compiler-rt: notices/compiler-rt/LICENSE.TXT differs from its receipt")
        self.make()
        write(self.path("notices/llvm@22/LICENSE.TXT"), "Apache License\n")
        self.assertRefused("does not contain 'LLVM Exceptions'")


class AbsentComponentTest(BundleCase):
    def assertRefused(self, fragment):
        rc, output = self.run_cli()
        self.assertEqual(rc, 1, output)
        self.assertIn(fragment, output)

    def test_a_notice_of_a_component_no_receipt_names_is_refused(self):
        write(self.path("runtime/notices/openssl/LICENSE"))
        self.assertRefused("runtime/notices/openssl/LICENSE names a component no receipt says is present")

    def test_a_notice_stays_refused_when_the_receipt_that_needed_it_goes(self):
        os.remove(self.path("runtime/windows/notices/windows-provenance.json"))
        self.assertRefused("runtime/windows/notices/mingw-w64/COPYING names a component no receipt says is present")

    def test_a_receipt_of_an_unknown_kind_or_a_bundle_without_an_engine_receipt_is_refused(self):
        receipt(self.path("runtime/notices/new-provenance.json"), kind="local-new-runtime")
        self.assertRefused("runtime/notices/new-provenance.json has kind 'local-new-runtime', which has no notices rule")
        os.remove(self.path("runtime/notices/new-provenance.json"))
        os.remove(self.path("notices/provenance.json"))
        self.assertRefused("the engine receipt, is missing")


class EngineKindsTest(BundleCase):
    def test_the_linux_windows_and_upstream_engine_receipts_name_their_license(self):
        for kind, fields, license_ in (
                ("local-linux-package-proof", {"packages": [{"name": "llvm-22", "copyright": "notices/llvm-22/copyright"}]},
                 "notices/llvm-22/copyright"),
                ("local-windows-llvm-proof", {"license": {"sha256": pe.sha256File(self.path("notices/llvm@22/LICENSE.TXT"))}},
                 "notices/LICENSE.TXT"),
                ("upstream-release-subset", {}, "notices/llvm-project/LICENSE.TXT")):
            with self.subTest(kind):
                self.make()
                shutil.rmtree(self.path("notices/llvm@22"))
                shutil.rmtree(self.path("notices/zstd"))
                receipt(self.path("notices/provenance.json"), kind=kind, **fields)
                self.assertEqual(pn.problemsOf(self.root)[0][0].endswith("%s is missing or empty" % license_), True)
                write(self.path(license_), LLVM_TEXT)
                self.assertEqual(pn.problemsOf(self.root)[0], [])


if __name__ == "__main__":
    unittest.main()
