"""Prove that the notices of a bundle are the notices of the third-party components its own receipts name.

    prepareNotices.py BUNDLE_DIR

A component is present when a provenance receipt under a `notices/` directory says so: an engine package, the zig
files of a `local-zig-*` receipt, the libc a runtime target links (glibc, musl, wasi-libc by target name), the C++ and
Windows components a receipt lists, the compiler-rt of the sanitizer receipt. Each present component needs its license
file as a non-empty regular file beside the receipt (the LLVM family and the libc ones also need the license's own
words), and every file under a `notices/` directory must belong to a present component, so a notice for a component
the payload no longer carries is an error too. A receipt of a kind this file has no rule for is an error.
"""
import json
import os
import sys

import prepareEngine as pe

NOTICE_ROOTS = ("notices", "runtime/notices", "runtime/windows/notices", "runtime/darwin/notices")
LLVM = "LLVM Exceptions"
PHRASES = {("llvm", "LICENSE.TXT"): LLVM, ("lld", "LICENSE.TXT"): LLVM, ("llvm-project", "LICENSE.TXT"): LLVM,
           ("compiler-rt", "LICENSE.TXT"): LLVM, ("libcxx", "LICENSE.TXT"): LLVM, ("libcxxabi", "LICENSE.TXT"): LLVM,
           ("libunwind", "LICENSE.TXT"): LLVM, ("glibc", "LICENSES"): "Lesser General Public License",
           ("musl", "COPYRIGHT"): "MIT license", ("zig", "LICENSE"): "MIT License"}
LIBC_BY_TARGET = (("-linux-gnu", ["glibc/LICENSES"]), ("-linux-musl", ["musl/COPYRIGHT"]),
                  ("wasm32-wasi", ["wasi-libc/LICENSE", "musl/COPYRIGHT"]))
OWN_KINDS = ("local-bundle-assembly",)


def need(requirements, component, relative, sha256=None):
    requirements.setdefault(relative, (component, sha256))


def zigRequirements(requirements, receipt, base):
    if "zig" in receipt:
        need(requirements, "zig", os.path.join(base, "notices", "zig", "LICENSE"))
    for relative in receipt.get("notices", []):
        need(requirements, relative.split("/")[-2], os.path.join(base, relative))
    for target in receipt.get("targets", []):
        if not isinstance(target, dict):
            continue
        for relative in target.get("notices", []):
            need(requirements, relative.split("/")[-2], os.path.join(base, relative))
        for marker, files in LIBC_BY_TARGET:
            if marker in str(target.get("target", target.get("config", ""))):
                for relative in files:
                    need(requirements, relative.split("/")[0], os.path.join(base, "notices", relative))


def engineRequirements(requirements, receipt):
    kind = receipt["kind"]
    if kind == "local-homebrew-proof":
        for package in receipt["packages"]:
            for relative in package["licenses"] + ([package["sbom"]] if package.get("sbom") else []):
                need(requirements, package["name"], relative)
    elif kind == "local-linux-package-proof":
        for package in receipt["packages"]:
            need(requirements, package["name"], package["copyright"], package.get("copyrightSha256"))
    elif kind == "local-windows-llvm-proof":
        need(requirements, "llvm-project", "notices/LICENSE.TXT", receipt["license"]["sha256"])
    elif kind == "local-source-engine-proof":
        licenses = receipt.get("licenses", {})
        for component in ("llvm", "compiler-rt"):
            digest = licenses.get(component) if isinstance(licenses, dict) else None
            if digest is None:
                raise pe.EngineError("source engine: missing license sha256 for " + component)
            if not isinstance(digest, str) or len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
                raise pe.EngineError("source engine: invalid license sha256 for " + component)
            need(requirements, component, "notices/%s/LICENSE.TXT" % component, digest)
    else:
        need(requirements, "llvm-project", "notices/llvm-project/LICENSE.TXT")


def receiptsOf(root):
    """[(path relative to root, base directory relative to root, parsed receipt)]."""
    found = []
    for notices in NOTICE_ROOTS:
        directory = os.path.join(root, notices)
        for here, _, names in sorted(os.walk(directory)):
            for name in sorted(names):
                if name.endswith("provenance.json"):
                    relative = os.path.relpath(os.path.join(here, name), root)
                    with open(os.path.join(root, relative), encoding="utf-8") as f:
                        found.append((relative, os.path.dirname(notices), json.load(f)))
    return found


def shippedNotices(root):
    shipped = []
    for notices in NOTICE_ROOTS:
        for here, _, names in os.walk(os.path.join(root, notices)):
            shipped += [os.path.relpath(os.path.join(here, n), root) for n in names if not n.endswith("provenance.json")]
    return sorted(shipped)


def problemsOf(root):
    problems, requirements, gaps = [], {}, []
    receipts = receiptsOf(root)
    if not any(path == "notices/provenance.json" for path, _, _ in receipts):
        problems.append("notices/provenance.json, the engine receipt, is missing")
    for path, base, receipt in receipts:
        kind = receipt.get("kind", "")
        gaps += ["%s: %s" % (path, gap) for gap in receipt.get("noticeGaps", [])]
        if kind in ("local-homebrew-proof", "local-linux-package-proof", "local-windows-llvm-proof",
                    "upstream-release-subset", "local-source-engine-proof"):
            engineRequirements(requirements, receipt)
        elif kind.startswith("local-zig-"):
            zigRequirements(requirements, receipt, base)
        elif kind == "local-source-sanitizer-runtime":
            need(requirements, "compiler-rt", "notices/compiler-rt/LICENSE.TXT", receipt["source"]["compilerRtLicenseSha256"])
        elif kind not in OWN_KINDS:
            problems.append("%s has kind %r, which has no notices rule" % (path, kind))
    for relative, (component, sha256) in sorted(requirements.items()):
        full = os.path.join(root, relative)
        if not os.path.isfile(full) or os.path.islink(full) or os.path.getsize(full) == 0:
            problems.append("%s: %s is missing or empty" % (component, relative))
            continue
        if sha256 and pe.sha256File(full) != sha256:
            problems.append("%s: %s differs from its receipt" % (component, relative))
        phrase = PHRASES.get((component.split("@")[0], os.path.basename(relative)))
        with open(full, encoding="utf-8", errors="replace") as f:
            if phrase and phrase.lower() not in f.read().lower():
                problems.append("%s: %s does not contain %r" % (component, relative, phrase))
    for relative in shippedNotices(root):
        if relative not in requirements:
            problems.append("%s names a component no receipt says is present" % relative)
    return problems, len(requirements), gaps


def verifyNotices(root):
    """(notice files proved, the gaps the receipts record themselves), or EngineError naming every mismatch."""
    problems, count, gaps = problemsOf(root)
    if problems:
        raise pe.EngineError("notices do not match the payload:\n  " + "\n  ".join(problems))
    return count, gaps


def report(root):
    count, gaps = verifyNotices(root)
    print("notices match the receipts: files=%d" % count)
    for gap in gaps:
        print("recorded notice gap: " + gap)


def main(argv):
    if len(argv) != 1:
        print("usage: prepareNotices.py BUNDLE_DIR", file=sys.stderr)
        return 2
    try:
        report(argv[0])
    except pe.EngineError as error:
        print("prepareNotices: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
