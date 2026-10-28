#!/usr/bin/env python3
"""Prepare a relocatable native clang/lld engine bundle for Linux x86_64 from an installed LLVM and lld.

    prepareLinuxEngine.py --llvm-root DIR --lld-root DIR --output NEW_DIR --patchelf PATH [--library-dir DIR ...]
    prepareLinuxEngine.py --verify BUNDLE_DIR [--inspector LLVM_READOBJ]

The bundle has the layout, aliases and contract files of prepareEngine.py (HOST x86_64-linux). Every ELF of bin/
and of the dependency closure in lib/ is read by an llvm-readobj, never run: the machine must be x86_64, the loader the system one,
each GLIBC version it needs at most GLIBC_BASELINE, and each other needed library is copied under its soname.
The bundle carries bin/llvm-readobj, the inspector of the LLVM root it was prepared with. Preparing reads with that
source file; verifying reads with the bundle's own bin/llvm-readobj, after the contract and layout hold, and only
on a native Linux x86_64 host. A bundle on another host is audited with an explicit --inspector, never by running
its ELF files. The glibc family and the loader stay the host's. Each copied ELF gets its own RUNPATH, `$ORIGIN` plus the way to
lib/ and none when it needs nothing bundled, written by the explicit --patchelf tool; no other RUNPATH survives.

A dependency is searched in the explicit --library-dir roots first, in order, then in the RUNPATH of the object
that needs it, then in the host directories. A library root is laid out like a filesystem root with its package
control file (`dpkg-deb -R` of one package: DEBIAN/control and usr/lib/x86_64-linux-gnu/...), so a library
the host has only in a newer glibc generation can be replaced by the package of the baseline. ELF files under
lib/clang/ are target runtimes carried as data and not audited.

The bundle is a local proof built from installed packages, not an upstream-controlled build; its provenance
receipt names the package, version, source file and hash of every copied file and never certifies redistribution.
"""
import argparse
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile

import prepareEngine as pe
import prepareRuntime as pr

ELF_MACHINE = 62
ELF_TYPES = {1: "ET_REL", 2: "ET_EXEC", 3: "ET_DYN", 4: "ET_CORE"}
INTERPRETER = "/lib64/ld-linux-x86-64.so.2"
GLIBC_BASELINE = (2, 39)
SYSTEM_LIBRARIES = frozenset((
    "ld-linux-x86-64.so.2", "libBrokenLocale.so.1", "libanl.so.1", "libc.so.6", "libdl.so.2", "libm.so.6",
    "libmvec.so.1", "libpthread.so.0", "libresolv.so.2", "librt.so.1", "libthread_db.so.1", "libutil.so.1"))
LIBRARY_DIRS = ("lib/x86_64-linux-gnu", "usr/lib/x86_64-linux-gnu", "lib64", "usr/lib64", "lib", "usr/lib")
HOST_ROOT = "/"
RESOURCE_PREFIX = "lib/clang/"
GLIBC_NAME = re.compile(r"^GLIBC_(\d+(?:\.\d+)*)$")
BUILTINS = "lib/clang/%s/lib/linux/libclang_rt.builtins-x86_64.a"
INSPECTOR = "llvm-readobj"
TOOLS = pe.LLVM_TOOLS + (INSPECTOR,)

JSON_FLAGS = ("--elf-output-style=JSON", "--file-headers", "--program-headers", "--dynamic-table", "--needed-libs")
VERSION_FLAGS = ("--elf-output-style=GNU", "--version-info")
INTERPRETER_LIMIT = 4096
SINGLE_TAGS = ("SONAME", "RUNPATH", "RPATH", "STRTAB", "VERNEED", "VERNEEDNUM", "VERDEF", "VERDEFNUM")
ELF_TYPE = re.compile(r"\(0x([0-9a-f]+)\)$")
VERSION_SECTION = re.compile(r"^Version (symbols|definition|needs) section '[^']+' contains (\d+) entries:$")
VERDEF_LINE = re.compile(r"^  0x[0-9a-f]+: Rev: \d+  Flags: (.+?)  Index: \d+  Cnt: (\d+)  Name: (\S+)$")
VERDEF_PARENT_LINE = re.compile(r"^  0x[0-9a-f]+: Parent (\d+): (\S+)$")
VERNEED_FILE_LINE = re.compile(r"^  0x[0-9a-f]+: Version: \d+  File: (\S+)  Cnt: (\d+)$")
VERNEED_NAME_LINE = re.compile(r"^  0x[0-9a-f]+:   Name: (\S+)  Flags: .+?  Version: \d+$")


def detectHost():
    if not sys.platform.startswith("linux"):
        raise pe.EngineError("unsupported host %s: only native Linux x86_64 is implemented" % sys.platform)
    if platform.machine() != "x86_64":
        raise pe.EngineError("unsupported host linux %s: only x86_64 is implemented" % platform.machine())
    return pe.LINUX_X64


def isElf(path):
    with open(path, "rb") as f:
        return f.read(4) == b"\x7fELF"


def inspect(inspector, flags, path):
    """The stdout of one inspector run on path; a nonzero exit or any stderr is an error."""
    done = subprocess.run([inspector, *flags, path], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)
    if done.returncode != 0:
        raise pe.EngineError("%s: %s failed (%d): %s" % (path, os.path.basename(inspector), done.returncode, done.stderr.strip()))
    if done.stderr.strip():
        raise pe.EngineError("%s: %s warned: %s" % (path, os.path.basename(inspector), done.stderr.strip()))
    return done.stdout


def member(node, key, kind, path, where):
    value = node.get(key) if isinstance(node, dict) else None
    if type(value) is not kind:
        raise pe.EngineError("%s: inspector JSON has no %s %s" % (path, where, kind.__name__))
    return value


def readInterpreter(path, header):
    offset, size = member(header, "Offset", int, path, "PT_INTERP Offset"), member(header, "FileSize", int, path, "PT_INTERP FileSize")
    if size < 1 or size > INTERPRETER_LIMIT or offset < 0 or offset + size > os.path.getsize(path):
        raise pe.EngineError("%s: PT_INTERP at %d, %d bytes, is not inside the file or is over %d bytes" % (
            path, offset, size, INTERPRETER_LIMIT))
    with open(path, "rb") as f:
        f.seek(offset)
        text = f.read(size)
    if not text.endswith(b"\0") or b"\0" in text[:-1]:
        raise pe.EngineError("%s: PT_INTERP is not one NUL-terminated path" % path)
    try:
        return text[:-1].decode("utf-8")
    except UnicodeDecodeError:
        raise pe.EngineError("%s: PT_INTERP is not UTF-8" % path)


def readVersions(path, text, verneedNum, verdefNum):
    """(verneed [(file, [version names])], verdef [version names without the base]) from the GNU style
    --version-info text, whose entry counts must equal the DT_VERNEEDNUM and DT_VERDEFNUM of the dynamic table."""
    section, declared, verneed, verdef, owed = None, {}, [], [], 0
    for line in text.splitlines():
        if not line.strip():
            if owed:
                raise pe.EngineError("%s: version definition %s is missing %d parent lines" % (path, verdef[-1] if verdef else "base", owed))
            section = None
            continue
        match = VERSION_SECTION.match(line)
        if owed and not (section == "definition" and VERDEF_PARENT_LINE.match(line)):
            raise pe.EngineError("%s: version definition %s is missing %d parent lines before %r" % (
                path, verdef[-1] if verdef else "base", owed, line))
        if match:
            section = match.group(1)
            if section in declared:
                raise pe.EngineError("%s: version-info has two %s sections" % (path, section))
            declared[section] = int(match.group(2))
        elif section == "symbols" or (section and line.startswith(" Addr:")):
            continue
        elif section == "definition":
            entry, parent = VERDEF_LINE.match(line), VERDEF_PARENT_LINE.match(line)
            if parent:
                if not owed or int(parent.group(1)) != parents:
                    raise pe.EngineError("%s: version definition parent %s out of order or beyond Cnt: %r" % (path, parent.group(1), line))
                owed -= 1
                parents += 1
            elif entry and int(entry.group(2)) >= 1:
                if "BASE" not in entry.group(1).split():
                    verdef.append(entry.group(3))
                declared["definitionEntries"] = declared.get("definitionEntries", 0) + 1
                owed, parents = int(entry.group(2)) - 1, 1
            else:
                raise pe.EngineError("%s: unrecognized version definition line %r" % (path, line))
        elif section == "needs":
            file, name = VERNEED_FILE_LINE.match(line), VERNEED_NAME_LINE.match(line)
            if file:
                verneed.append((file.group(1), int(file.group(2)), []))
            elif name and verneed:
                verneed[-1][2].append(name.group(1))
            else:
                raise pe.EngineError("%s: unrecognized version needs line %r" % (path, line))
        else:
            raise pe.EngineError("%s: unrecognized version-info line %r" % (path, line))
    if owed:
        raise pe.EngineError("%s: version definition %s is missing %d parent lines at the end of the text" % (path, verdef[-1] if verdef else "base", owed))
    for label, found, number in (("definition", declared.get("definitionEntries", 0), verdefNum),
                                 ("needs", len(verneed), verneedNum)):
        if declared.get(label, 0) != number or found != number:
            raise pe.EngineError("%s: version %s: dynamic table says %d, section declares %d and holds %d" % (
                path, label, number, declared.get(label, 0), found))
    for file, count, names in verneed:
        if len(names) != count:
            raise pe.EngineError("%s: version needs of %s declare %d names and hold %d" % (path, file, count, len(names)))
    return [(file, names) for file, _, names in verneed], verdef


def readElf(path, inspector):
    """The dynamic facts of a 64-bit little-endian ELF as a dict, or None when path is not ELF. The facts come from
    the inspector; anything it does not report, or reports twice or inconsistently, is an error."""
    with open(path, "rb") as f:
        head = f.read(6)
    if head[:4] != b"\x7fELF":
        return None
    if len(head) < 6 or head[4] != 2 or head[5] != 1:
        raise pe.EngineError("%s: not a 64-bit little-endian ELF" % path)
    try:
        documents = json.loads(inspect(inspector, JSON_FLAGS, path))
    except json.JSONDecodeError as error:
        raise pe.EngineError("%s: inspector output is not JSON: %s" % (path, error))
    if not isinstance(documents, list) or len(documents) != 1:
        raise pe.EngineError("%s: inspector JSON is not one document" % path)
    document = documents[0]
    header = member(document, "ElfHeader", dict, path, "ElfHeader")
    ident = member(header, "Ident", dict, path, "ElfHeader.Ident")
    if (member(member(ident, "Class", dict, path, "Ident.Class"), "Value", int, path, "Ident.Class.Value"),
            member(member(ident, "DataEncoding", dict, path, "Ident.DataEncoding"), "Value", int, path, "Ident.DataEncoding.Value")) != (2, 1):
        raise pe.EngineError("%s: the inspector reads another class or byte order than the file header" % path)
    kind = ELF_TYPE.search(member(header, "Type", str, path, "ElfHeader.Type"))
    if not kind:
        raise pe.EngineError("%s: ElfHeader.Type has no numeric value" % path)
    info = {"type": int(kind.group(1), 16),
            "machine": member(member(header, "Machine", dict, path, "ElfHeader.Machine"), "Value", int, path, "Machine.Value"),
            "interpreter": None, "needed": [], "soname": None, "runpath": None, "rpath": None, "verneed": [], "verdef": []}
    headers = [member(h, "ProgramHeader", dict, path, "ProgramHeaders entry") for h in member(document, "ProgramHeaders", list, path, "ProgramHeaders")]
    kinds = [member(member(h, "Type", dict, path, "ProgramHeader.Type"), "Name", str, path, "ProgramHeader.Type.Name") for h in headers]
    for name in ("PT_INTERP", "PT_DYNAMIC"):
        if kinds.count(name) > 1:
            raise pe.EngineError("%s: has %d %s program headers" % (path, kinds.count(name), name))
    if "PT_INTERP" in kinds:
        info["interpreter"] = readInterpreter(path, headers[kinds.index("PT_INTERP")])
    dynamic = document.get("DynamicSection", [])
    if not isinstance(dynamic, list) or (dynamic and "PT_DYNAMIC" not in kinds):
        raise pe.EngineError("%s: inspector reports a dynamic table the program headers do not have" % path)
    counts = {}
    for entry in dynamic:
        tag = member(entry, "Type", str, path, "DynamicSection Type")
        counts[tag] = counts.get(tag, 0) + 1
        if tag in SINGLE_TAGS and counts[tag] > 1:
            raise pe.EngineError("%s: dynamic table has %d %s entries" % (path, counts[tag], tag))
        if tag == "NEEDED":
            info["needed"].append(member(entry, "Library", str, path, "NEEDED Library"))
        elif tag == "SONAME":
            info["soname"] = member(entry, "Name", str, path, "SONAME Name")
        elif tag in ("RUNPATH", "RPATH"):
            parts = member(entry, "Path", list, path, tag + " Path")
            if not all(type(p) is str for p in parts):
                raise pe.EngineError("%s: %s Path is not a list of strings" % (path, tag))
            info[tag.lower()] = ":".join(parts)
        elif tag in ("VERNEEDNUM", "VERDEFNUM"):
            counts[tag + "="] = member(entry, "Value", int, path, tag + " Value")
    listed = document.get("NeededLibraries", [])
    if not isinstance(listed, list) or not all(type(n) is str for n in listed) or sorted(listed) != sorted(info["needed"]):
        raise pe.EngineError("%s: NEEDED entries and NeededLibraries disagree" % path)
    info["verneed"], info["verdef"] = readVersions(path, inspect(inspector, VERSION_FLAGS, path),
                                                   counts.get("VERNEEDNUM=", 0), counts.get("VERDEFNUM=", 0))
    return info


def limitProblem(info):
    if info["machine"] != ELF_MACHINE:
        return "machine %d, not x86_64" % info["machine"]
    if info["interpreter"] not in (None, INTERPRETER):
        return "interpreter %s is not %s" % (info["interpreter"], INTERPRETER)
    for file, names in info["verneed"]:
        if file not in SYSTEM_LIBRARIES:
            continue
        for name in names:
            match = GLIBC_NAME.match(name)
            if not match:
                return "needs %s of %s, which is not a versioned GLIBC symbol" % (name, file)
            if tuple(int(n) for n in match.group(1).split(".")) > GLIBC_BASELINE:
                return "needs %s of %s, above the %s baseline" % (name, file, ".".join(map(str, GLIBC_BASELINE)))
    return None


def libraryDirectories(root):
    return [os.path.join(root, d) for d in LIBRARY_DIRS]


def describeRoot(root):
    """The package a library root holds, from its DEBIAN/control, with the copyright file it ships."""
    control = os.path.join(root, "DEBIAN", "control")
    if not os.path.isfile(control):
        raise pe.EngineError("%s: no DEBIAN/control" % root)
    if not pe.containsPath(root, os.path.realpath(control)):
        raise pe.EngineError("%s: DEBIAN/control leaves package root %s" % (root, root))
    fields = {}
    with open(control, encoding="utf-8") as f:
        for line in f:
            key, separator, value = line.partition(":")
            if separator and not key[:1].isspace():
                fields.setdefault(key, value.strip())
    for key in ("Package", "Version"):
        if not fields.get(key):
            raise pe.EngineError("%s: DEBIAN/control has no %s" % (root, key))
    copyright = os.path.join(root, "usr", "share", "doc", pr.checkName(fields["Package"]), "copyright")
    if not os.path.isfile(copyright):
        raise pe.EngineError("%s: no copyright file at %s" % (fields["Package"], copyright))
    if not pe.containsPath(root, os.path.realpath(copyright)):
        raise pe.EngineError("%s: copyright leaves package root %s" % (fields["Package"], root))
    return {"name": fields["Package"], "version": fields["Version"], "copyright": copyright,
            "source": "extracted package " + root}


def hostPackageOwners(paths):
    owners = {}
    for line in pe.run(["dpkg-query", "-S", "--"] + list(paths)).splitlines():
        packages, separator, path = line.partition(": ")
        if separator:
            owners[path] = packages.split(", ")
    return owners


def hostPackage(name):
    version = pe.run(["dpkg-query", "-W", "-f=${Version}", name]).strip()
    copyright = os.path.join(HOST_ROOT, "usr", "share", "doc", pr.checkName(name.split(":")[0]), "copyright")
    if not os.path.isfile(copyright):
        raise pe.EngineError("%s: no copyright file at %s" % (name, copyright))
    return version, copyright


def runpathDirectories(owner, info):
    directories = []
    for value in (info["rpath"], info["runpath"]):
        for entry in [] if value is None else value.split(":"):
            expanded = entry
            for token in ("$ORIGIN", "${ORIGIN}"):
                if entry.startswith(token):
                    expanded = os.path.dirname(os.path.realpath(owner)) + entry[len(token):]
            if "$" in expanded:
                raise pe.EngineError("%s: unsupported RUNPATH entry %s" % (owner, entry))
            if not expanded.startswith("/"):
                raise pe.EngineError("%s: relative RUNPATH entry %r" % (owner, entry))
            directories.append(expanded)
    return directories


def findLibrary(name, owner, directories, libraryRoots):
    candidates = [(d, root) for root in libraryRoots for d in libraryDirectories(root)]
    candidates += [(d, "host") for d in directories + libraryDirectories(HOST_ROOT)]
    for directory, origin in candidates:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            real = os.path.realpath(path)
            if origin != "host" and not pe.containsPath(origin, real):
                raise pe.EngineError("%s: %s leaves library root %s" % (owner, path, origin))
            return real, origin
    raise pe.EngineError("%s: cannot find %s; searched %s" % (owner, name, ", ".join(d for d, _ in candidates)))


def roleProblem(rel, info):
    if rel.startswith("lib/") and os.path.basename(rel) in SYSTEM_LIBRARIES:
        return "is a host-provided system library, never bundled"
    kind = "ELF type %d (%s)" % (info["type"], ELF_TYPES.get(info["type"], "unknown"))
    if rel.startswith("bin/"):
        if info["type"] not in (2, 3):
            return "%s is not ET_EXEC or ET_DYN, required of %s" % (kind, rel)
        if info["interpreter"] is None:
            return "has no interpreter"
    elif rel.startswith("lib/"):
        if info["type"] != 3:
            return "%s is not ET_DYN, required of %s" % (kind, rel)
        if info["soname"] != os.path.basename(rel):
            return "soname is %s, not %s" % (info["soname"], os.path.basename(rel))
    return None


def planClosure(plan, origins, libraryRoots, inspector):
    queue = sorted(plan)
    while queue:
        dest = queue.pop()
        source = plan[dest]
        if dest.startswith(RESOURCE_PREFIX):
            continue
        info = readElf(source, inspector)
        if info is None:
            raise pe.EngineError("%s: not an ELF executable" % source)
        problem = limitProblem(info)
        if problem:
            raise pe.EngineError("%s: %s" % (source, problem))
        problem = roleProblem(dest, info)
        if problem:
            raise pe.EngineError("%s: %s" % (source, problem))
        directories = runpathDirectories(source, info)
        for name in info["needed"]:
            if name in SYSTEM_LIBRARIES:
                continue
            if "/" in name:
                raise pe.EngineError("%s: needs %s by a path" % (source, name))
            found, origin = findLibrary(name, source, directories, libraryRoots)
            wanted = "lib/" + name
            if wanted not in plan:
                plan[wanted], origins[wanted] = found, origin
                queue.append(wanted)
            elif not pe.sameFile(plan[wanted], found):
                raise pe.EngineError("%s collides: %s and %s" % (wanted, plan[wanted], found))
    return plan


def collectPackages(plan, origins, described):
    hostSources = sorted({source for dest, source in plan.items() if origins.get(dest, "host") == "host"})
    owners = hostPackageOwners(hostSources) if hostSources else {}
    packages, named = {}, {}
    for dest, source in sorted(plan.items()):
        origin = origins.get(dest, "host")
        if origin == "host":
            if not owners.get(source):
                raise pe.EngineError("no package owns %s" % source)
            records = []
            for owner in owners[source]:
                version, copyright = hostPackage(owner)
                records.append({"name": owner.split(":")[0], "version": version, "copyright": copyright,
                                "source": "host dpkg"})
        else:
            records = [described[origin]]
        for record in records:
            known = packages.setdefault(record["name"], dict(record, files=0))
            if (known["version"], known["source"]) != (record["version"], record["source"]):
                raise pe.EngineError("package %s is both %s %s and %s %s" % (
                    record["name"], known["version"], known["source"], record["version"], record["source"]))
            known["files"] += 1
        named[dest] = [r["name"] for r in records]
    return sorted(packages.values(), key=lambda r: r["name"]), named


def writeNotices(root, records):
    out = []
    for record in records:
        target = os.path.join(root, "notices", pr.checkName(record["name"]), "copyright")
        os.makedirs(os.path.dirname(target))
        shutil.copyfile(record["copyright"], target)
        out.append({"name": record["name"], "version": record["version"], "source": record["source"],
                    "files": record["files"], "copyright": "notices/%s/copyright" % record["name"],
                    "copyrightSha256": pe.sha256File(target)})
    return out


def writeProvenance(root, versions, tools, packages, files):
    receipt = {
        "kind": "local-linux-package-proof",
        "statement": "Prepared from locally installed packages. Not an upstream-controlled build.",
        "redistributionCertified": False,
        "host": pe.LINUX_X64,
        "clangVersion": versions[0],
        "lldVersion": versions[1],
        "glibcBaseline": ".".join(map(str, GLIBC_BASELINE)),
        "patchelf": tools["patchelf"],
        "inspector": tools["inspector"],
        "packages": packages,
        "files": files,
    }
    pe.writeText(os.path.join(root, "notices", "provenance.json"), json.dumps(receipt, indent=2, sort_keys=True) + "\n")


def bundleRunpath(root, path):
    relative = os.path.relpath(os.path.join(root, "lib"), os.path.dirname(path))
    return "$ORIGIN" if relative == "." else "$ORIGIN/" + relative


def wantedRunpath(root, path, info):
    return bundleRunpath(root, path) if any(n not in SYSTEM_LIBRARIES for n in info["needed"]) else None


def engineFiles(root):
    return [rel for rel in pe.listFiles(root)
            if not os.path.islink(os.path.join(root, rel))
            and (rel.startswith("bin/") or (rel.startswith("lib/") and not rel.startswith(RESOURCE_PREFIX)))]


def rewriteRunpath(patchelf, inspector, root, rel):
    path = os.path.join(root, rel)
    info = readElf(path, inspector)
    wanted = wantedRunpath(root, path, info)
    if (info["runpath"], info["rpath"]) == (wanted, None):
        return
    if info["runpath"] is not None or info["rpath"] is not None:
        pe.run([patchelf, "--remove-rpath", path])
    if wanted is not None:
        pe.run([patchelf, "--set-rpath", wanted, path])


def verifyLayout(root, version):
    major = version.split(".")[0]
    required = (["bin/clang-" + major] + ["bin/lld"] + ["bin/" + a for a in pe.CLANG_ALIASES + pe.LLD_ALIASES]
                + ["bin/" + t for t in TOOLS]
                + ["lib/clang/%s/include/stddef.h" % major, BUILTINS % major, "notices/provenance.json"])
    for rel in required:
        if not os.path.isfile(os.path.join(root, rel)):
            raise pe.EngineError("layout: missing %s" % rel)


def bundledInspector(root):
    try:
        detectHost()
    except pe.EngineError as error:
        raise pe.EngineError("%s: cannot run the bundle's own bin/%s here (%s); pass --inspector" % (root, INSPECTOR, error))
    path = os.path.join(root, "bin", INSPECTOR)
    if os.path.islink(path):
        raise pe.EngineError("bin/%s is a symlink" % INSPECTOR)
    return path


def verifyEngine(root, host, version, inspector=None):
    if host != pe.LINUX_X64:
        raise pe.EngineError("%s is not a %s bundle" % (root, pe.LINUX_X64))
    verifyLayout(root, version)
    inspector = inspector or bundledInspector(root)
    if not os.path.isfile(inspector) or not os.access(inspector, os.X_OK):
        raise pe.EngineError("--inspector %s is not an executable file" % inspector)
    infos = {}
    for rel in engineFiles(root):
        path = os.path.join(root, rel)
        info = readElf(path, inspector)
        if info is None:
            raise pe.EngineError("%s: not an ELF executable" % rel)
        infos[rel] = info
    for rel, info in infos.items():
        path = os.path.join(root, rel)
        problem = limitProblem(info)
        if problem:
            raise pe.EngineError("%s: %s" % (rel, problem))
        problem = roleProblem(rel, info)
        if problem:
            raise pe.EngineError("%s: %s" % (rel, problem))
        for name in info["needed"]:
            if "/" in name:
                raise pe.EngineError("%s: needs %s by a path" % (rel, name))
            if name not in SYSTEM_LIBRARIES and "lib/" + name not in infos:
                raise pe.EngineError("%s: needs %s, which is not in lib/" % (rel, name))
        if info["rpath"] is not None:
            raise pe.EngineError("%s: has DT_RPATH %s" % (rel, info["rpath"]))
        wanted = wantedRunpath(root, path, info)
        if info["runpath"] != wanted:
            raise pe.EngineError("%s: runpath is %s, expected %s" % (
                rel, info["runpath"], "none" if wanted is None else wanted))
        for file, names in info["verneed"]:
            if file in SYSTEM_LIBRARIES:
                continue
            for name in names:
                if name not in infos["lib/" + file]["verdef"]:
                    raise pe.EngineError("%s: needs %s of %s, which the bundled file does not define" % (rel, name, file))
    return len(infos)


def prepareEngine(llvmRoot, lldRoot, output, libraryDirs=(), patchelf=None):
    host = detectHost()
    llvmRoot, lldRoot, output = (os.path.abspath(p) for p in (llvmRoot, lldRoot, output))
    libraryDirs = [os.path.abspath(d) for d in libraryDirs]
    for role, path in (("llvm-root", llvmRoot), ("lld-root", lldRoot)):
        if not os.path.isdir(path):
            raise pe.EngineError("--%s %s is not a directory" % (role, path))
    for path in libraryDirs:
        if not os.path.isdir(path):
            raise pe.EngineError("--library-dir %s is not a directory" % path)
    if not patchelf or not os.path.isfile(patchelf) or not os.access(patchelf, os.X_OK):
        raise pe.EngineError("--patchelf %s is not an executable file" % patchelf)
    patchelf = os.path.abspath(patchelf)
    inspector = os.path.join(llvmRoot, "bin", INSPECTOR)
    if not os.path.isfile(inspector) or not os.access(inspector, os.X_OK):
        raise pe.EngineError("--llvm-root has no executable bin/%s to inspect ELF files with" % INSPECTOR)
    if os.path.lexists(output):
        raise pe.EngineError("output %s exists; it is never replaced" % output)
    parent = os.path.realpath(os.path.dirname(output))
    if any(pe.containsPath(r, parent) for r in (llvmRoot, lldRoot)):
        raise pe.EngineError("output must not be inside a source root")
    if any(pe.containsPath(r, parent) for r in libraryDirs):
        raise pe.EngineError("output must not be inside a library root")
    described = {d: describeRoot(d) for d in libraryDirs}
    tools = {"patchelf": {"version": pe.run([patchelf, "--version"]).strip(), "sha256": pe.sha256File(patchelf)},
             "inspector": {"version": pe.toolVersion(inspector, r"LLVM version (\d+\.\d+\.\d+)"),
                           "sha256": pe.sha256File(inspector)}}

    version = pe.toolVersion(os.path.join(llvmRoot, "bin", "clang"), r"clang version (\d+\.\d+\.\d+)")
    lldVersion = pe.toolVersion(os.path.join(lldRoot, "bin", "ld.lld"), r"LLD (\d+\.\d+\.\d+)")
    if lldVersion != version:
        raise pe.EngineError("lld %s does not match clang %s" % (lldVersion, version))
    major = version.split(".")[0]

    plan = {"bin/lld": os.path.join(lldRoot, "bin", "lld"),
            "bin/clang-" + major: os.path.join(llvmRoot, "bin", "clang")}
    for tool in TOOLS:
        plan["bin/" + tool] = os.path.join(llvmRoot, "bin", tool)
    resource = os.path.join(llvmRoot, "lib", "clang", major)
    if not os.path.isdir(resource):
        raise pe.EngineError("missing resource directory %s" % resource)
    for directory, dirnames, filenames in os.walk(resource):
        for name in dirnames + filenames:
            if os.path.islink(os.path.join(directory, name)):
                raise pe.EngineError("symlink in resource directory: %s" % name)
        for name in filenames:
            source = os.path.join(directory, name)
            plan["lib/clang/%s/%s" % (major, os.path.relpath(source, resource))] = source
    for dest, source in plan.items():
        if not os.path.isfile(source):
            raise pe.EngineError("missing source file %s" % source)
    origins = {}
    planClosure(plan, origins, libraryDirs, inspector)
    plan = {dest: os.path.realpath(source) for dest, source in plan.items()}
    records, named = collectPackages(plan, origins, described)

    os.makedirs(os.path.dirname(output), exist_ok=True)
    partial = tempfile.mkdtemp(prefix=os.path.basename(output) + ".partial-", dir=os.path.dirname(output))
    try:
        for dest, source in sorted(plan.items()):
            target = os.path.join(partial, dest)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copyfile(source, target)
            os.chmod(target, 0o755 if os.access(source, os.X_OK) else 0o644)
        for rel in engineFiles(partial):
            rewriteRunpath(patchelf, inspector, partial, rel)
        for alias in pe.CLANG_ALIASES:
            os.symlink("clang-" + major, os.path.join(partial, "bin", alias))
        for alias in pe.LLD_ALIASES:
            os.symlink("lld", os.path.join(partial, "bin", alias))
        packages = writeNotices(partial, records)
        files = [{"path": dest, "source": plan[dest], "sourceSha256": pe.sha256File(plan[dest]),
                  "origin": origins.get(dest, "host"), "package": ", ".join(named[dest])}
                 for dest in sorted(plan) if not dest.startswith(RESOURCE_PREFIX)]
        writeProvenance(partial, (version, lldVersion), tools, packages, files)
        pe.writeContract(partial, host, version)
        verified = pe.verifyEngine(partial, inspector)
        os.chmod(partial, 0o755)
        pr.renameNoReplace(partial, output)
    except BaseException:
        shutil.rmtree(partial, ignore_errors=True)
        raise
    return output, verified, plan, records


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--llvm-root")
    parser.add_argument("--lld-root")
    parser.add_argument("--output")
    parser.add_argument("--patchelf")
    parser.add_argument("--library-dir", action="append", default=[])
    parser.add_argument("--verify", metavar="BUNDLE_DIR")
    parser.add_argument("--inspector")
    args = parser.parse_args(argv)
    try:
        if args.verify:
            host, version = pe.verifyContract(args.verify)
            if host != pe.LINUX_X64:
                raise pe.EngineError("%s is a %s bundle, not %s" % (args.verify, host, pe.LINUX_X64))
            print("verified host=%s version=%s elf=%d" % (host, version, verifyEngine(args.verify, host, version, args.inspector)))
            return 0
        if not (args.llvm_root and args.lld_root and args.output and args.patchelf):
            parser.error("--llvm-root, --lld-root, --output and --patchelf are required")
        output, (host, version, count), plan, records = prepareEngine(
            args.llvm_root, args.lld_root, args.output, args.library_dir, args.patchelf)
        with open(os.path.join(output, "IDENTITY"), encoding="utf-8") as f:
            identity = f.read().strip()
        sources = sorted({p for d in [args.llvm_root, args.lld_root] + args.library_dir
                          for p in (os.path.abspath(d), os.path.realpath(d))})
        print("prepared %s" % output)
        print("host=%s version=%s identity=%s" % (host, version, identity))
        print("files=%d elf=%d bytes=%d" % (len(pe.listFiles(output)), count,
                                            sum(os.path.getsize(os.path.join(output, r)) for r in pe.listFiles(output))))
        print("packages=%s" % ",".join("%s-%s" % (r["name"], r["version"]) for r in records))
        for rel, found in pe.sourcePathLiterals(output, sources, isElf).items():
            print("source path literal in data: %s x%d" % (rel, found))
        print("redistribution NOT certified; local proof from installed packages")
        return 0
    except pe.EngineError as error:
        print("prepareLinuxEngine: error: %s" % error, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
