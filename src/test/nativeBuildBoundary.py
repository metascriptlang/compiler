# Pipeline boundary test: unlike c/*.ms, this must span candidate compiler processes to observe persistent native caches.
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

compiler = str(Path(sys.argv[1] if len(sys.argv) > 1 else "msc").resolve())
group = sys.argv[2] if len(sys.argv) > 2 else "all"
root = Path(tempfile.mkdtemp(prefix="msc-native-boundary-", dir="/tmp")).resolve()
results = []


def command(cwd, label, argv, env=None):
    result = subprocess.run(argv, cwd=cwd, capture_output=True, text=True, env=env)
    (cwd / (label + ".log")).write_text(result.stdout + result.stderr)
    return result


def fixture(name, directives, native, header="", native_name="native.c"):
    cwd = root / name
    cwd.mkdir()
    (cwd / "build.ms").write_text("const config = {};\nexport default config;\n")
    (cwd / "api.h").write_text("int probeValue(void);\n")
    (cwd / "main.ms").write_text('@include("./api.h");\n' + directives + '\nextern function probeValue(): int32;\nconsole.log(probeValue());\n')
    (cwd / native_name).write_text(native)
    (cwd / "value.h").write_text(header)
    return cwd


def build(cwd, label, output="probe", flags=(), env=None, cc=None):
    argv = [compiler, "build", "main.ms", "--output=" + output, *flags]
    if cc is not None:
        argv.insert(3, "--cc=" + cc)
    elif os.name != "nt":
        argv.insert(3, "--cc=clang")
    return command(cwd, label, argv, env)


def value(cwd, output="probe"):
    return subprocess.check_output([str(cwd / output)], text=True).strip()


def record(name, expected, actual):
    results.append({"case": name, "expected": expected, "actual": actual, "pass": expected == actual})


def run_compile_cache():
    source = fixture("source", '@compile("./native.c");', "int probeValue(void) { return 11; }\n")
    assert build(source, "baseline").returncode == 0
    assert value(source) == "11"
    (source / "native.c").write_text("int probeValue(void) { return 22; }\n")
    assert build(source, "source-change").returncode == 0
    record("native source edit", "22", value(source))

    header = fixture("header", '@compile("./native.c");', '#include "value.h"\nint probeValue(void) { return VALUE; }\n', "#define VALUE 11\n")
    assert build(header, "baseline").returncode == 0
    assert value(header) == "11"
    (header / "value.h").write_text("#define VALUE 22\n")
    assert build(header, "header-change").returncode == 0
    record("native header edit", "22", value(header))
    assert build(header, "new-output", output="probe2").returncode == 0
    record("header edit bypassing project cache", "22", value(header, "probe2"))
    assert build(header, "force", output="probe2", flags=("--force",)).returncode == 0
    record("header edit with force and global cache", "22", value(header, "probe2"))
    uncached = dict(os.environ, MSC_NO_GLOBAL_CACHE="1")
    assert build(header, "uncached-control", output="probe2", flags=("--force",), env=uncached).returncode == 0
    record("uncached diagnostic control", "22", value(header, "probe2"))

def run_link_cache():
    archive = fixture("archive", '@link("./libnative.a");', "int probeValue(void) { return 17; }\n")
    for label in ("initial", "changed"):
        if label == "changed":
            (archive / "native.c").write_text("int probeValue(void) { return 29; }\n")
        assert command(archive, "cc-" + label, ["clang", "-c", "native.c", "-o", "native.o"]).returncode == 0
        assert command(archive, "ar-" + label, ["ar", "rcs", "libnative.a", "native.o"]).returncode == 0
        assert build(archive, label).returncode == 0
        if label == "initial":
            assert value(archive) == "17"
    record("linked archive replacement", "29", value(archive))

    (archive / "native.c").write_text("int otherValue(void) { return 31; }\n")
    assert command(archive, "cc-broken", ["clang", "-c", "native.c", "-o", "native.o"]).returncode == 0
    assert command(archive, "ar-broken", ["ar", "rcs", "libnative.a", "native.o"]).returncode == 0
    first_failure = build(archive, "link-failure")
    second_failure = build(archive, "link-failure-retry")
    record("failed link rejects stale output", True, first_failure.returncode != 0)
    record("failed link remains invalidated", True, second_failure.returncode != 0)


def make_archive(cwd, name, result):
    source = name + ".c"
    obj = name + ".o"
    archive = name + ".a"
    (cwd / source).write_text("int probeValue(void) { return %d; }\n" % result)
    assert command(cwd, "cc-" + name, ["clang", "-c", source, "-o", obj]).returncode == 0
    assert command(cwd, "ar-" + name, ["ar", "rcs", archive, obj]).returncode == 0
    return cwd / archive


def run_audit():
    link_options = fixture("link options", "", "")
    first_archive = make_archive(link_options, "first", 41)
    second_archive = make_archive(link_options, "second", 43)
    assert build(link_options, "first-link-option", flags=('--passL="' + str(first_archive) + '"',)).returncode == 0
    assert value(link_options) == "41"
    assert build(link_options, "second-link-option", flags=('--passL="' + str(second_archive) + '"',)).returncode == 0
    record("link option change", "43", value(link_options))

    configured = fixture(
        "configured options",
        '@compile("./native.c");',
        "int probeValue(void) { return TARGET_ARCH + SDK_VERSION + DEPLOYMENT_TARGET; }\n",
    )
    (configured / "build.ms").write_text(
        'const config = { cc: { flags: ["-DTARGET_ARCH=2", "-DSDK_VERSION=17", "-DDEPLOYMENT_TARGET=14"] } };\n'
        "export default config;\n"
    )
    assert build(configured, "first-config").returncode == 0
    assert value(configured) == "33"
    (configured / "build.ms").write_text(
        'const config = { cc: { flags: ["-DTARGET_ARCH=4", "-DSDK_VERSION=18", "-DDEPLOYMENT_TARGET=15"] } };\n'
        "export default config;\n"
    )
    assert build(configured, "second-config").returncode == 0
    record("configured arch SDK and deployment options", "37", value(configured))

    toolchain = fixture(
        "toolchain",
        '@compile("./native.c");',
        "int probeValue(void) { return TOOL_VALUE; }\n",
    )
    if os.name == "nt":
        wrapper = toolchain / "cc-wrapper.exe"
        wrapper_source = toolchain / "cc-wrapper.c"
        zig = (Path.home() / ".metascript" / "zig" / "zig.exe").as_posix()

        def write_wrapper(value):
            wrapper_source.write_text(
                "#include <process.h>\n#include <stdlib.h>\n"
                "int main(int argc, char **argv) {\n"
                "  char **args = malloc(sizeof(char *) * (argc + 3));\n"
                f'  args[0] = "{zig}";\n'
                '  args[1] = "cc";\n'
                f'  args[2] = "-DTOOL_VALUE={value}";\n'
                "  for (int i = 1; i < argc; i++) args[i + 2] = argv[i];\n"
                "  args[argc + 2] = NULL;\n"
                f'  return (int)_spawnv(_P_WAIT, "{zig}", (const char * const *)args);\n'
                "}\n"
            )
            subprocess.run(["gcc", str(wrapper_source), "-o", str(wrapper)], check=True)
    else:
        wrapper = toolchain / "cc-wrapper"

        def write_wrapper(value):
            wrapper.write_text(f'#!/bin/sh\nexec clang -DTOOL_VALUE={value} "$@"\n')
            wrapper.chmod(0o755)

    write_wrapper(47)
    assert build(toolchain, "first-toolchain", cc=str(wrapper)).returncode == 0
    assert value(toolchain) == "47"
    write_wrapper(49)
    assert build(toolchain, "second-toolchain", cc=str(wrapper)).returncode == 0
    record("compiler binary replacement", "49", value(toolchain))

    mode = fixture(
        "mode",
        '@compile("./native.c");',
        "#ifdef __OPTIMIZE__\nint probeValue(void) { return 53; }\n#else\nint probeValue(void) { return 51; }\n#endif\n",
    )
    assert build(mode, "debug").returncode == 0
    assert value(mode) == "51"
    assert build(mode, "release", flags=("--release",)).returncode == 0
    record("debug release isolation", "53", value(mode))

    moved = fixture("moved source", '@compile("./native.c");', "int probeValue(void) { return 59; }\n")
    assert build(moved, "before-remove").returncode == 0
    (moved / "native.c").unlink()
    removed = build(moved, "removed")
    record("removed native source rejects stale output", True, removed.returncode != 0)
    (moved / "renamed.c").write_text("int probeValue(void) { return 61; }\n")
    (moved / "main.ms").write_text(
        '@include("./api.h");\n@compile("./renamed.c");\n'
        "extern function probeValue(): int32;\nconsole.log(probeValue());\n"
    )
    assert build(moved, "renamed").returncode == 0
    record("renamed native source", "61", value(moved))

    failed = fixture("failed compile", '@compile("./native.c");', "int probeValue(void) { return 67; }\n")
    assert build(failed, "before-failure").returncode == 0
    (failed / "native.c").write_text("int probeValue(void) { this is not C; }\n")
    first_failure = build(failed, "compile-failure")
    second_failure = build(failed, "compile-failure-retry")
    record("failed compile rejects stale output", True, first_failure.returncode != 0)
    record("failed compile remains invalidated", True, second_failure.returncode != 0)


def run_argv():
    spaces = fixture("spaces", '@compile("./native.c");', "int probeValue(void) { return 31; }\n")
    output = "products with spaces/probe"
    record("executable output path with spaces", 0, build(spaces, "output-spaces", output=output).returncode)
    archive_output = "products with spaces/libProbe.a"
    archive_result = build(spaces, "archive-output-spaces", output=archive_output, flags=("--app=staticlib",))
    record("static archive output path with spaces", 0, archive_result.returncode)
    if archive_result.returncode == 0:
        members = command(spaces, "archive-members", ["ar", "t", archive_output])
        record("static archive retains spaced object path", 0, members.returncode)

    source = fixture("source path", '@compile("./native source.c");', "int probeValue(void) { return 37; }\n", native_name="native source.c")
    source_result = build(source, "source-path")
    record("native source path with spaces", 0, source_result.returncode)
    if source_result.returncode == 0:
        record("native source path executable", "37", value(source))

    include = fixture("include path", '@compile("./native.c");\n@passC("-I\\\"headers with spaces\\\"");', "#include <value.h>\nint probeValue(void) { return VALUE; }\n")
    include_dir = include / "headers with spaces"
    include_dir.mkdir()
    (include_dir / "value.h").write_text("#define VALUE 41\n")
    include_result = build(include, "include-path")
    record("native include path with spaces", 0, include_result.returncode)
    if include_result.returncode == 0:
        record("native include path executable", "41", value(include))

    quoted = fixture("quoted flag", '@compile("./native.c");\n@passC("-DLABEL=\'\\\"a b\\\"\'");', "int probeValue(void) { return sizeof(LABEL); }\n")
    quoted_result = build(quoted, "quoted-flag")
    record("quoted flag value", 0, quoted_result.returncode)
    if quoted_result.returncode == 0:
        record("quoted flag value executable", "4", value(quoted))

    response = fixture("response file", '@compile("./native.c");', "int probeValue(void) { return 47; }\n")
    flag_template = "--passL=-LC:/tmp/native-boundary-%04d" if os.name == "nt" else "--passL=-L/tmp/native-boundary-%04d"
    flag_count = 820 if os.name == "nt" else 900
    long_flags = tuple(flag_template % i for i in range(flag_count))
    response_result = build(response, "response-file", output="products with spaces/response probe", flags=long_flags)
    record("response file preserves arguments", 0, response_result.returncode)
    if response_result.returncode == 0:
        record("response file executable", "47", value(response, "products with spaces/response probe"))


if group in ("argv", "all"):
    run_argv()
if group in ("compile-cache", "all"):
    run_compile_cache()
if group in ("link-cache", "all"):
    run_link_cache()
if group in ("audit", "all"):
    run_audit()
if group not in ("argv", "compile-cache", "link-cache", "audit", "all"):
    raise SystemExit("group must be argv, compile-cache, link-cache, audit, or all")

print(json.dumps({"root": str(root), "results": results}, indent=2))
sys.exit(0 if all(item["pass"] for item in results) else 1)
