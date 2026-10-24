#!/usr/bin/env python3
"""Prepare a relocatable native clang/lld engine bundle from local LLVM and lld roots.

    prepareEngine.py --llvm-root DIR --lld-root DIR --output NEW_DIR
    prepareEngine.py --verify BUNDLE_DIR

The bundle is a local proof built from installed packages, not an upstream-controlled
build; its provenance receipt says so and never certifies redistribution.
"""
import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys

HOSTS = {"arm64": ("aarch64-macos", 0x0100000C), "x86_64": ("x86_64-macos", 0x01000007)}
LLVM_TOOLS = ("llvm-ar", "llvm-ranlib", "llvm-strip", "llvm-objcopy", "llvm-nm", "dsymutil")
CLANG_ALIASES = ("clang", "clang++")
LLD_ALIASES = ("ld64.lld", "ld.lld", "lld-link", "wasm-ld")
SYSTEM_PREFIXES = ("/usr/lib/", "/System/")
CONTRACT_FILES = ("FILES.sha256", "IDENTITY")
LICENSE_NAME = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE)", re.IGNORECASE)
RECEIPT_KEYS = ("homebrew_version", "built_as_bottle", "poured_from_bottle", "compiler",
                "time", "source_modified_time", "arch")
LOAD_COMMANDS = ("LC_LOAD_DYLIB", "LC_LOAD_WEAK_DYLIB", "LC_REEXPORT_DYLIB",
                 "LC_LOAD_UPWARD_DYLIB", "LC_LAZY_LOAD_DYLIB")
MH_EXECUTE = 2
MAGIC_MACHO64 = 0xFEEDFACF
LINE_RE = re.compile(r"^(name|path) (.*) \(offset \d+\)$")
HASH_LINE_RE = re.compile(r"^([0-9a-f]{64})  (.+)\n$")


class EngineError(Exception):
    pass


def run(command):
    done = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if done.returncode != 0:
        raise EngineError("%s failed (%d): %s" % (" ".join(command), done.returncode,
                                                  done.stderr.strip()))
    return done.stdout


def detectHost():
    if sys.platform != "darwin":
        raise EngineError("unsupported host %s: only native macOS is implemented" % sys.platform)
    machine = platform.machine()
    if machine not in HOSTS:
        raise EngineError("unsupported macOS machine %s" % machine)
    return HOSTS[machine]


def machoSlices(path):
    """Return [(cputype, filetype)] for the 64-bit Mach-O slices of path; [] when it has none."""
    with open(path, "rb") as f:
        head = f.read(8)
        if head[:4] == b"\xca\xfe\xba\xbf":
            raise EngineError("%s: 64-bit fat header is unsupported" % path)
        offsets = []
        if head[:4] == b"\xca\xfe\xba\xbe":
            count = struct.unpack(">I", head[4:8])[0]
            if count > 16:
                return []
            for _ in range(count):
                entry = f.read(20)
                offsets.append(struct.unpack(">5I", entry)[2])
        elif len(head) == 8 and struct.unpack("<I", head[:4])[0] == MAGIC_MACHO64:
            offsets.append(0)
        slices = []
        for offset in offsets:
            f.seek(offset)
            header = f.read(16)
            if len(header) == 16:
                magic, cpu, _, filetype = struct.unpack("<4I", header)
                if magic == MAGIC_MACHO64:
                    slices.append((cpu, filetype))
        return slices


def loadCommands(path):
    """Return (ids, deps, rpaths), each an ordered list without duplicates across slices."""
    ids, deps, rpaths, command = [], [], [], None
    for line in run(["/usr/bin/otool", "-l", path]).splitlines():
        text = line.strip()
        if text.startswith("cmd "):
            command = text[4:]
            continue
        match = LINE_RE.match(text)
        if not match:
            continue
        if command == "LC_ID_DYLIB" and match.group(1) == "name":
            ids.append(match.group(2))
        elif command in LOAD_COMMANDS and match.group(1) == "name":
            deps.append(match.group(2))
        elif command == "LC_RPATH" and match.group(1) == "path":
            rpaths.append(match.group(2))
    return list(dict.fromkeys(ids)), list(dict.fromkeys(deps)), list(dict.fromkeys(rpaths))


def isSystem(dep):
    return dep.startswith(SYSTEM_PREFIXES)


def resolveDependency(dep, owner, rpaths, isExecutable):
    """Find the file a load command of owner names; None for a system library."""
    if isSystem(dep):
        return None
    base = os.path.dirname(owner)
    if dep.startswith("@executable_path/") and not isExecutable:
        raise EngineError("%s: @executable_path dependency %s of a non-executable" % (owner, dep))
    if dep.startswith(("@loader_path/", "@executable_path/")):
        candidates = [os.path.join(base, dep.split("/", 1)[1])]
    elif dep.startswith("@rpath/"):
        candidates = []
        for rpath in rpaths:
            if rpath.startswith("@loader_path"):
                rpath = base + rpath[len("@loader_path"):]
            elif rpath.startswith("@executable_path"):
                rpath = base + rpath[len("@executable_path"):]
            candidates.append(os.path.join(rpath, dep[len("@rpath/"):]))
    elif dep.startswith("/"):
        candidates = [dep]
    else:
        raise EngineError("%s: unsupported load command %s" % (owner, dep))
    for candidate in candidates:
        if os.path.isfile(candidate):
            return os.path.realpath(candidate)
    raise EngineError("%s: cannot resolve dependency %s" % (owner, dep))


def sameFile(a, b):
    return os.path.realpath(a) == os.path.realpath(b) or (
        os.path.getsize(a) == os.path.getsize(b) and sha256File(a) == sha256File(b))


def planClosure(plan, cpu):
    """Add every non-system dylib reachable from the plan to lib/, keyed by destination."""
    queue = list(plan.items())
    while queue:
        _, source = queue.pop()
        slices = machoSlices(source)
        if not slices:
            continue
        if cpu not in {c for c, _ in slices}:
            raise EngineError("%s has no slice for this host" % source)
        _, deps, rpaths = loadCommands(source)
        isExecutable = any(t == MH_EXECUTE for _, t in slices)
        for dep in deps:
            found = resolveDependency(dep, source, rpaths, isExecutable)
            if found is None:
                continue
            dest = "lib/" + os.path.basename(dep)
            if dest not in plan:
                plan[dest] = found
                queue.append((dest, found))
            elif not sameFile(plan[dest], found):
                raise EngineError("%s collides: %s and %s" % (dest, plan[dest], found))
    return plan


def toolVersion(binary, pattern):
    match = re.search(pattern, run([binary, "--version"]))
    if not match:
        raise EngineError("%s: version not recognized" % binary)
    return match.group(1)


def licenseFiles(directory):
    return sorted(n for n in os.listdir(directory)
                  if LICENSE_NAME.match(n) and os.path.isfile(os.path.join(directory, n)))


def packageIdentity(directory, version):
    """Name and version of the package installed at directory (Cellar/<name>/<version> layout)."""
    parent = os.path.dirname(directory)
    if os.path.basename(os.path.dirname(parent)) == "Cellar":
        return os.path.basename(parent), os.path.basename(directory)
    return os.path.basename(directory), version


def dependencyPackageDir(library):
    directory = os.path.dirname(library)
    for _ in range(3):
        if licenseFiles(directory):
            return directory
        directory = os.path.dirname(directory)
    raise EngineError("%s: no license file within three directories above it" % library)


def collectPackages(plan, roots):
    """roots: [(role, realpath, version)]. Returns package records with license sources."""
    packages = {}
    for role, directory, version in roots:
        packages[directory] = (role, directory, version)
    for dest, source in sorted(plan.items()):
        if os.path.dirname(dest) == "lib" and not any(
                os.path.realpath(source).startswith(root[1] + os.sep) for root in roots):
            directory = dependencyPackageDir(source)
            packages.setdefault(directory, ("dependency", directory, None))
    records = []
    for role, directory, version in packages.values():
        licenses = licenseFiles(directory)
        if not licenses:
            raise EngineError("%s: no license file in %s" % (role, directory))
        name, resolved = packageIdentity(directory, version or "unknown")
        records.append({"role": role, "name": name, "version": resolved, "directory": directory,
                        "licenses": licenses})
    names = [r["name"] for r in records]
    if len(set(names)) != len(names):
        raise EngineError("package names collide: %s" % names)
    return sorted(records, key=lambda r: r["name"])


def writeNotices(root, records):
    out = []
    for record in records:
        target = os.path.join(root, "notices", record["name"])
        os.makedirs(target)
        copied = {"licenses": []}
        for name in record["licenses"]:
            shutil.copyfile(os.path.join(record["directory"], name), os.path.join(target, name))
            copied["licenses"].append("notices/%s/%s" % (record["name"], name))
        sbom = os.path.join(record["directory"], "sbom.spdx.json")
        copied["sbom"] = None
        if os.path.isfile(sbom):
            shutil.copyfile(sbom, os.path.join(target, "sbom.spdx.json"))
            copied["sbom"] = "notices/%s/sbom.spdx.json" % record["name"]
        receipt = os.path.join(record["directory"], "INSTALL_RECEIPT.json")
        copied["receiptSha256"] = sha256File(receipt) if os.path.isfile(receipt) else None
        copied["receipt"] = None
        if copied["receiptSha256"]:
            with open(receipt, encoding="utf-8") as f:
                data = json.load(f)
            copied["receipt"] = {k: data[k] for k in RECEIPT_KEYS if k in data}
        out.append({"role": record["role"], "name": record["name"], "version": record["version"],
                    **copied})
    return out


def writeProvenance(root, host, versions, packages):
    receipt = {
        "kind": "local-homebrew-proof",
        "statement": "Prepared from locally installed packages. Not an upstream-controlled build.",
        "redistributionCertified": False,
        "host": host,
        "clangVersion": versions[0],
        "lldVersion": versions[1],
        "packages": packages,
    }
    with open(os.path.join(root, "notices", "provenance.json"), "w", encoding="utf-8") as f:
        f.write(json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def rewriteLoadCommands(path, root):
    """Point every non-system load command at the bundle and ad-hoc sign the copy."""
    ids, deps, rpaths = loadCommands(path)
    if len(ids) > 1:
        raise EngineError("%s: several install names %s" % (path, ids))
    args = []
    for ident in ids:
        wanted = "@rpath/" + os.path.basename(path)
        if ident != wanted:
            args += ["-id", wanted]
    external = False
    for dep in deps:
        if isSystem(dep):
            continue
        external = True
        wanted = "@rpath/" + os.path.basename(dep)
        if dep != wanted:
            args += ["-change", dep, wanted]
    relative = os.path.relpath(os.path.join(root, "lib"), os.path.dirname(path))
    needed = "@loader_path" if relative == "." else "@loader_path/" + relative
    for rpath in rpaths:
        if not (external and rpath == needed):
            args += ["-delete_rpath", rpath]
    if external and needed not in rpaths:
        args += ["-add_rpath", needed]
    if args:
        run(["/usr/bin/install_name_tool"] + args + [path])
    run(["/usr/bin/codesign", "-f", "-s", "-", path])


def sha256File(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def listFiles(root):
    """Relative paths of every file and symlink in root, sorted by UTF-8 bytes, contract files
    excluded. A symlink must resolve to a regular file inside root."""
    real = os.path.realpath(root)
    found = []
    for directory, dirnames, filenames in os.walk(root):
        for name in dirnames:
            if os.path.islink(os.path.join(directory, name)):
                raise EngineError("directory symlink %s" % os.path.join(directory, name))
        for name in filenames:
            path = os.path.join(directory, name)
            rel = os.path.relpath(path, root)
            if "\n" in rel or "\\" in rel:
                raise EngineError("unsupported character in path %r" % rel)
            try:
                rel.encode("utf-8")
            except UnicodeEncodeError:
                raise EngineError("path is not UTF-8: %r" % rel)
            if os.path.islink(path):
                target = os.path.realpath(path)
                if os.path.commonpath([real, target]) != real or not os.path.isfile(target):
                    raise EngineError("symlink %s leaves the bundle or is not a file" % rel)
            if rel not in CONTRACT_FILES:
                found.append(rel)
    return sorted(found, key=lambda r: r.encode("utf-8"))


def writeText(path, text):
    with open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def writeContract(root, host, version):
    writeText(os.path.join(root, "HOST"), host + "\n")
    writeText(os.path.join(root, "VERSION"), version + "\n")
    lines = "".join("%s  %s\n" % (sha256File(os.path.join(root, rel)), rel)
                    for rel in listFiles(root))
    writeText(os.path.join(root, "FILES.sha256"), lines)
    writeText(os.path.join(root, "IDENTITY"),
              hashlib.sha256(lines.encode("utf-8")).hexdigest() + "\n")


def readLine(root, name, pattern):
    with open(os.path.join(root, name), encoding="utf-8", newline="") as f:
        text = f.read()
    if not re.fullmatch("(?:%s)\n" % pattern, text):
        raise EngineError("%s is not one line matching %s: %r" % (name, pattern, text))
    return text[:-1]


def verifyContract(root):
    host = readLine(root, "HOST", "|".join(re.escape(h[0]) for h in HOSTS.values()))
    version = readLine(root, "VERSION", r"\d+\.\d+\.\d+")
    with open(os.path.join(root, "FILES.sha256"), "rb") as f:
        raw = f.read()
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError:
        raise EngineError("FILES.sha256 is not UTF-8")
    listed = []
    for line in text.splitlines(keepends=True):
        match = HASH_LINE_RE.match(line)
        if not match:
            raise EngineError("FILES.sha256: bad line %r" % line)
        rel = match.group(2)
        parts = rel.split("/")
        if rel.startswith("/") or "\\" in rel or any(p in ("", ".", "..") for p in parts):
            raise EngineError("FILES.sha256: unsafe path %r" % rel)
        listed.append((match.group(1), rel))
    paths = [rel for _, rel in listed]
    if paths != sorted(set(paths), key=lambda r: r.encode("utf-8")):
        raise EngineError("FILES.sha256: paths are not unique and sorted")
    actual = listFiles(root)
    if paths != actual:
        raise EngineError("FILES.sha256 lists %s, bundle has %s" % (
            sorted(set(paths) ^ set(actual)), "different files"))
    for digest, rel in listed:
        if sha256File(os.path.join(root, rel)) != digest:
            raise EngineError("hash mismatch: %s" % rel)
    for required in ("HOST", "VERSION"):
        if required not in paths:
            raise EngineError("FILES.sha256 omits %s" % required)
    if readLine(root, "IDENTITY", "[0-9a-f]{64}") != hashlib.sha256(raw).hexdigest():
        raise EngineError("IDENTITY does not match FILES.sha256")
    return host, version


def verifyLayout(root, version):
    major = version.split(".")[0]
    required = ["bin/clang-" + major, "bin/lld", "bin/clang", "bin/clang++", "bin/ld64.lld",
                "lib/clang/%s/include/stddef.h" % major,
                "lib/clang/%s/lib/darwin/libclang_rt.osx.a" % major,
                "notices/provenance.json"]
    for rel in required + ["bin/" + t for t in LLVM_TOOLS]:
        if not os.path.isfile(os.path.join(root, rel)):
            raise EngineError("layout: missing %s" % rel)


def auditLoadCommands(root):
    """Every Mach-O in root loads only system libraries or bundle files through its own rpaths."""
    real = os.path.realpath(root)
    count = 0
    for rel in listFiles(root):
        path = os.path.join(real, rel)
        if os.path.islink(os.path.join(root, rel)) or not machoSlices(path):
            continue
        count += 1
        ids, deps, rpaths = loadCommands(path)
        for ident in ids:
            if ident != "@rpath/" + os.path.basename(path):
                raise EngineError("%s: install name %s" % (rel, ident))
        resolved = []
        for rpath in rpaths:
            if rpath != "@loader_path" and not rpath.startswith("@loader_path/"):
                raise EngineError("%s: rpath %s is not bundle-relative" % (rel, rpath))
            resolved.append(os.path.normpath(os.path.dirname(path) + rpath[len("@loader_path"):]))
        for dep in deps:
            if isSystem(dep):
                continue
            if not dep.startswith("@rpath/"):
                raise EngineError("%s: external loader dependency %s" % (rel, dep))
            hits = [d for d in resolved if os.path.isfile(os.path.join(d, dep[len("@rpath/"):]))
                    and os.path.commonpath([real, d]) == real]
            if not hits:
                raise EngineError("%s: %s does not resolve inside the bundle" % (rel, dep))
        run(["/usr/bin/codesign", "--verify", "--strict", path])
    return count


def verifyEngine(root):
    host, version = verifyContract(root)
    verifyLayout(root, version)
    return host, version, auditLoadCommands(root)


def containsPath(parent, child):
    return os.path.commonpath([parent, child]) == parent


def prepareEngine(llvmRoot, lldRoot, output):
    host, cpu = detectHost()
    llvmRoot, lldRoot, output = (os.path.abspath(p) for p in (llvmRoot, lldRoot, output))
    for role, path in (("llvm", llvmRoot), ("lld", lldRoot)):
        if not os.path.isdir(path):
            raise EngineError("--%s-root %s is not a directory" % (role, path))
    realRoots = [os.path.realpath(llvmRoot), os.path.realpath(lldRoot)]
    if os.path.lexists(output):
        raise EngineError("output %s exists; it is never replaced" % output)
    if any(containsPath(r, os.path.realpath(os.path.dirname(output))) for r in realRoots):
        raise EngineError("output must not be inside a source root")

    version = toolVersion(os.path.join(llvmRoot, "bin", "clang"), r"clang version (\d+\.\d+\.\d+)")
    lldVersion = toolVersion(os.path.join(lldRoot, "bin", "ld64.lld"), r"LLD (\d+\.\d+\.\d+)")
    if lldVersion != version:
        raise EngineError("lld %s does not match clang %s" % (lldVersion, version))
    major = version.split(".")[0]

    plan = {"bin/lld": os.path.join(lldRoot, "bin", "lld"),
            "bin/clang-" + major: os.path.join(llvmRoot, "bin", "clang-" + major)}
    for tool in LLVM_TOOLS:
        plan["bin/" + tool] = os.path.join(llvmRoot, "bin", tool)
    resource = os.path.join(llvmRoot, "lib", "clang", major)
    if not os.path.isdir(resource):
        raise EngineError("missing resource directory %s" % resource)
    for directory, dirnames, filenames in os.walk(resource):
        for name in dirnames + filenames:
            if os.path.islink(os.path.join(directory, name)):
                raise EngineError("symlink in resource directory: %s" % name)
        for name in filenames:
            source = os.path.join(directory, name)
            plan["lib/clang/%s/%s" % (major, os.path.relpath(source, resource))] = source
    for dest, source in plan.items():
        if not os.path.isfile(source):
            raise EngineError("missing source file %s" % source)
    planClosure(plan, cpu)
    records = collectPackages(plan, [("llvm", realRoots[0], version), ("lld", realRoots[1], version)])

    os.makedirs(os.path.dirname(output), exist_ok=True)
    try:
        os.mkdir(output)
    except FileExistsError:
        raise EngineError("output %s exists; it is never replaced" % output)
    for dest, source in plan.items():
        target = os.path.join(output, dest)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copyfile(source, target)
        os.chmod(target, 0o755 if os.access(source, os.X_OK) else 0o644)
    for dest in sorted(plan):
        if machoSlices(os.path.join(output, dest)):
            rewriteLoadCommands(os.path.join(output, dest), output)
    for alias in CLANG_ALIASES:
        os.symlink("clang-" + major, os.path.join(output, "bin", alias))
    for alias in LLD_ALIASES:
        os.symlink("lld", os.path.join(output, "bin", alias))
    packages = writeNotices(output, records)
    writeProvenance(output, host, (version, lldVersion), packages)
    writeContract(output, host, version)
    verified = verifyEngine(output)
    return output, verified, plan, records


def sourcePathLiterals(root, sources):
    """Count source-root path strings left as data in Mach-O files (not load commands)."""
    needles = [s.encode("utf-8") for s in sources]
    counts = {}
    for rel in listFiles(root):
        path = os.path.join(root, rel)
        if os.path.islink(path) or not machoSlices(path):
            continue
        with open(path, "rb") as f:
            data = f.read()
        total = sum(data.count(n) for n in needles)
        if total:
            counts[rel] = total
    return counts


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--llvm-root")
    parser.add_argument("--lld-root")
    parser.add_argument("--output")
    parser.add_argument("--verify", metavar="BUNDLE_DIR")
    args = parser.parse_args(argv)
    try:
        if args.verify:
            host, version, macho = verifyEngine(args.verify)
            print("verified host=%s version=%s macho=%d" % (host, version, macho))
            return 0
        if not (args.llvm_root and args.lld_root and args.output):
            parser.error("--llvm-root, --lld-root and --output are required")
        output, (host, version, macho), plan, records = prepareEngine(
            args.llvm_root, args.lld_root, args.output)
        with open(os.path.join(output, "IDENTITY"), encoding="utf-8") as f:
            identity = f.read().strip()
        sources = sorted({os.path.abspath(args.llvm_root), os.path.abspath(args.lld_root)}
                         | {os.path.realpath(args.llvm_root), os.path.realpath(args.lld_root)})
        print("prepared %s" % output)
        print("host=%s version=%s identity=%s" % (host, version, identity))
        print("files=%d macho=%d bytes=%d" % (
            len(listFiles(output)), macho,
            sum(os.path.getsize(os.path.join(output, r)) for r in listFiles(output))))
        print("packages=%s" % ",".join("%s-%s" % (r["name"], r["version"]) for r in records))
        for rel, count in sourcePathLiterals(output, sources).items():
            print("source path literal in data: %s x%d" % (rel, count))
        print("redistribution NOT certified; local proof from installed packages")
        return 0
    except EngineError as error:
        print("prepareEngine: error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
