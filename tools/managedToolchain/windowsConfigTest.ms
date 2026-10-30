import {
	WindowsTarget, WindowsVariant, windowsTargetName, parseWindowsTarget,
	windowsVariantDirectory, windowsConfigPath, renderWindowsSourceConfig,
	renderWindowsCppConfig,
} from "./windowsConfig";

const EXE = "-target x86_64-w64-windows-gnu\n" +
	"-Xclang -target-cpu -Xclang x86-64\n" +
	"-nostdinc\n" +
	"-isystem <CFGDIR>/../../lib/clang/23/include\n" +
	"-isystem <CFGDIR>/include/libc/mingw-w64\n" +
	"--rtlib=compiler-rt\n--unwindlib=none\n" +
	"--ld-path=<CFGDIR>/../../bin/ld.lld\n" +
	"-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu\n" +
	"-resource-dir <CFGDIR>/../../lib/clang/23\n" +
	"--sysroot=<CFGDIR>/x86_64-windows-gnu\n" +
	"-B<CFGDIR>/x86_64-windows-gnu\n" +
	"-Xlinker --error-limit=0\n-Xlinker --stack=16777216\n" +
	"-Xlinker --image-base=0x140000000\n-Xlinker --build-id=none\n";
const CXX = "-stdlib=libc++\n" +
	"-isystem <CFGDIR>/x86_64-windows-gnu.cxx/include/c++/v1\n" +
	"-idirafter <CFGDIR>/x86_64-windows-gnu.cxx/include\n" +
	"-Xlinker -L -Xlinker <CFGDIR>/x86_64-windows-gnu.cxx\n" +
	"$-lc++\n$-lunwind\n";
let cases: int32 = 0;

function equal(actual: string, expected: string): void {
	if (actual != expected) { throw new Error("config contract bytes differ"); }
	cases += 1;
}

for (const target of [WindowsTarget.X64, WindowsTarget.Arm64]) {
	const name = target == WindowsTarget.X64 ?
		"x86_64-windows-gnu" : "aarch64-windows-gnu";
	equal(windowsTargetName(target), name);
	const parsed = parseWindowsTarget(name);
	if (!parsed.ok || parsed.value != target) {
		throw new Error("target parse changed");
	}
	cases += 1;
	const expected = target == WindowsTarget.X64 ? EXE : EXE
		.replaceAll("x86_64", "aarch64")
		.replaceAll("x86-64", "generic");
	for (const major of [22, 23]) {
		for (const variant of [WindowsVariant.Exe, WindowsVariant.Dll]) {
			let golden = expected.replaceAll("/23", "/" + String(major));
			const directory = name + (variant == WindowsVariant.Dll ? ".dll" : "");
			if (variant == WindowsVariant.Dll) {
				golden = golden
					.replaceAll("--unwindlib=none\n", "--unwindlib=none\n-shared\n")
					.replaceAll("<CFGDIR>/" + name, "<CFGDIR>/" + directory)
					.replaceAll("-Xlinker --stack=16777216\n", "")
					.replaceAll("0x140000000", "0x180000000");
			}
			const rendered = renderWindowsSourceConfig(target, variant, major);
			if (!rendered.ok) { throw new Error(rendered.error); }
			equal(rendered.value, golden);
			equal(windowsVariantDirectory(target, variant), directory);
			equal(windowsConfigPath(target, variant),
				"windows/" + directory + ".cfg");
			equal(windowsConfigPath(target, variant, true),
				"windows/" + directory + ".cxx.cfg");
			for (const forbidden of [
				"-nostdlib", "-nodefaultlibs", "-nostartfiles", "-nolibc",
				"-fsanitize", "asan", "ubsan", "crt2", "$-l", "-lgcc",
			]) {
				if (rendered.value.indexOf(forbidden) >= 0) {
					throw new Error("C config adds forbidden policy: " + forbidden);
				}
				cases += 1;
			}
		}
	}
	const cpp = renderWindowsCppConfig(target);
	equal(cpp, CXX.replaceAll("x86_64-windows-gnu", name));
	for (const forbidden of [
		"--unwindlib", "-nostdlib", "-lstdc++", "-lpthread",
		"-resource-dir", "--sysroot", "include/cxx",
	]) {
		if (cpp.indexOf(forbidden) >= 0) {
			throw new Error("C++ config adds forbidden policy: " + forbidden);
		}
		cases += 1;
	}
}
for (const major of [0, -1]) {
	if (renderWindowsSourceConfig(WindowsTarget.X64, WindowsVariant.Exe,
		major).ok) {
		throw new Error("accepted non-positive LLVM major");
	}
	cases += 1;
}
for (const target of [
	"i686-windows-gnu", "x86_64-windows-msvc", "../x", "", "aarch64-linux",
]) {
	if (parseWindowsTarget(target).ok) {
		throw new Error("accepted unsupported Windows target");
	}
	cases += 1;
}
console.log("source Windows configs: " + String(cases) + " cases OK");
