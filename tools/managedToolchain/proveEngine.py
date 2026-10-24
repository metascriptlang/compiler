#!/usr/bin/env python3
"""Relocate a prepared engine and compile, link and run C and C++20 with it under a sandbox.

    proveEngine.py --engine BUNDLE_DIR [--deny PATH ...]

The sandbox denies reads of the original bundle and every --deny path (source roots, other
toolchains), and the engine runs with an empty environment. The Apple SDK stays external.
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import prepareEngine

FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixtures")


def sdkPath():
    done = subprocess.run(["/usr/bin/xcrun", "--show-sdk-path"], stdout=subprocess.PIPE,
                          universal_newlines=True)
    path = done.stdout.strip()
    if done.returncode != 0 or not os.path.isdir(path):
        raise prepareEngine.EngineError("no Apple SDK from xcrun --show-sdk-path")
    return path


def sandboxed(profile, work, command):
    environment = {"PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "TMPDIR": work}
    return subprocess.run(["/usr/bin/sandbox-exec", "-f", profile] + command, env=environment,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)


def prove(engine, denied):
    original = os.path.realpath(engine)
    host, version, _ = prepareEngine.verifyEngine(original)
    sdk = sdkPath()
    work = os.path.realpath(tempfile.mkdtemp(prefix="engine-proof-"))
    moved = os.path.join(work, "relocated", "engine")
    shutil.copytree(original, moved, symlinks=True)
    rules = "".join('(deny file-read* (subpath "%s"))' % os.path.realpath(p)
                    for p in [original] + list(denied))
    profile = os.path.join(work, "deny.sb")
    with open(profile, "w") as f:
        f.write("(version 1)(allow default)" + rules + "\n")

    control = sandboxed(profile, work, [os.path.join(original, "bin", "clang"), "--version"])
    if control.returncode == 0:
        raise prepareEngine.EngineError("sandbox does not deny the original bundle")

    clang, clangxx = (os.path.join(moved, "bin", n) for n in ("clang", "clang++"))
    common = ["-isysroot", sdk, "-fuse-ld=lld"]
    c, cpp = os.path.join(FIXTURES, "c.c"), os.path.join(FIXTURES, "cpp.cpp")
    steps = [
        ("c", [clang, "-std=gnu11", "-O2"] + common + ["-c", c, "-o", "c.o"], None),
        ("c link", [clang] + common + ["c.o", "-o", "c.out", "-lm"], ("c.out", "c ok sum=14")),
        ("c++20", [clangxx, "-std=c++20", "-O2"] + common + ["-c", cpp, "-o", "cpp.o"], None),
        ("c++20 link", [clangxx] + common + ["cpp.o", "-o", "cpp.out"],
         ("cpp.out", "cpp20 ok boom alloc 1")),
        ("c++20 one-shot", [clangxx, "-std=c++20"] + common + [cpp, "-o", "cpp1.out"],
         ("cpp1.out", "cpp20 ok boom alloc 1")),
    ]
    for name, command, expect in steps:
        command = [os.path.join(work, a) if a.endswith((".o", ".out")) else a for a in command]
        done = sandboxed(profile, work, command)
        if done.returncode != 0:
            raise prepareEngine.EngineError("%s failed: %s" % (name, done.stderr.strip()))
        if expect:
            ran = subprocess.run([os.path.join(work, expect[0])], stdout=subprocess.PIPE,
                                 universal_newlines=True)
            if ran.returncode != 0 or expect[1] not in ran.stdout:
                raise prepareEngine.EngineError("%s output: %r" % (name, ran.stdout))
            print("%s: %s" % (name, ran.stdout.strip()))
        else:
            print("%s: compiled" % name)
    print("host=%s version=%s relocated=%s denied=%d" % (host, version, moved, len(denied) + 1))
    shutil.rmtree(work)


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--engine", required=True)
    parser.add_argument("--deny", action="append", default=[])
    args = parser.parse_args(argv)
    try:
        prove(args.engine, args.deny)
    except prepareEngine.EngineError as error:
        print("proveEngine: error: %s" % error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
