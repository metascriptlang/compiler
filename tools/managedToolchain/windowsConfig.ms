export enum WindowsTarget {
	X64,
	Arm64,
}

export enum WindowsVariant {
	Exe,
	Dll,
}

export function windowsTargetName(target: WindowsTarget): string {
	return match (target) {
		WindowsTarget.X64 => "x86_64-windows-gnu",
		WindowsTarget.Arm64 => "aarch64-windows-gnu",
	};
}

export function parseWindowsTarget(
	text: string,
): Result<WindowsTarget, string> {
	return match (text) {
		"x86_64-windows-gnu" => Result.ok(WindowsTarget.X64),
		"aarch64-windows-gnu" => Result.ok(WindowsTarget.Arm64),
		_ => Result.err("unsupported Windows target: " + text),
	};
}

export function windowsVariantDirectory(
	target: WindowsTarget,
	variant: WindowsVariant,
): string {
	const suffix = match (variant) {
		WindowsVariant.Exe => "",
		WindowsVariant.Dll => ".dll",
	};
	return windowsTargetName(target) + suffix;
}

export function windowsConfigPath(
	target: WindowsTarget,
	variant: WindowsVariant,
	cpp: boolean = false,
): string {
	return "windows/" + windowsVariantDirectory(target, variant) +
		(cpp ? ".cxx.cfg" : ".cfg");
}

export function renderWindowsSourceConfig(
	target: WindowsTarget,
	variant: WindowsVariant,
	major: int32,
): Result<string, string> {
	if (major < 1) { return Result.err("LLVM major must be positive"); }
	const directory = windowsVariantDirectory(target, variant);
	const resourceDirectory = "<CFGDIR>/../../lib/clang/" + String(major);
	const triple = match (target) {
		WindowsTarget.X64 => "x86_64-w64-windows-gnu",
		WindowsTarget.Arm64 => "aarch64-w64-windows-gnu",
	};
	const cpu = match (target) {
		WindowsTarget.X64 => "x86-64",
		WindowsTarget.Arm64 => "generic",
	};
	const imageBase = match (variant) {
		WindowsVariant.Exe => "0x140000000",
		WindowsVariant.Dll => "0x180000000",
	};
	const lines = [
		"-target " + triple,
		"-Xclang -target-cpu -Xclang " + cpu,
		"-nostdinc",
		"-isystem " + resourceDirectory + "/include",
		"-isystem <CFGDIR>/include/libc/mingw-w64",
		"--rtlib=compiler-rt",
		"--unwindlib=none",
	];
	if (variant == WindowsVariant.Dll) { lines.push("-shared"); }
	lines.push("--ld-path=<CFGDIR>/../../bin/ld.lld");
	lines.push("-Xlinker -L -Xlinker <CFGDIR>/" + directory);
	lines.push("-resource-dir " + resourceDirectory);
	lines.push("--sysroot=<CFGDIR>/" + directory);
	lines.push("-B<CFGDIR>/" + directory);
	lines.push("-Xlinker --error-limit=0");
	if (variant == WindowsVariant.Exe) {
		lines.push("-Xlinker --stack=16777216");
	}
	lines.push("-Xlinker --image-base=" + imageBase);
	lines.push("-Xlinker --build-id=none");
	return Result.ok(lines.join("\n") + "\n");
}

export function renderWindowsCppConfig(target: WindowsTarget): string {
	const directory = "<CFGDIR>/" + windowsTargetName(target) + ".cxx";
	return [
		"-stdlib=libc++",
		"-isystem " + directory + "/include/c++/v1",
		"-idirafter " + directory + "/include",
		"-Xlinker -L -Xlinker " + directory,
		"$-lc++",
		"$-lunwind",
	].join("\n") + "\n";
}
