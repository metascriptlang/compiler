export const MINIMUM_MACOS_VERSION = "11.0";
export const DARWIN_SYSROOT = "sysroot";
export const DARWIN_ENGINE_RELATIVE = "../..";

export enum DarwinTarget {
	Arm64,
	X64,
}

function canonicalTargets(): DarwinTarget[] {
	return [DarwinTarget.Arm64, DarwinTarget.X64];
}

export function darwinTargetName(target: DarwinTarget): string {
	return match (target) {
		DarwinTarget.Arm64 => "aarch64-macos",
		DarwinTarget.X64 => "x86_64-macos",
	};
}

export function parseDarwinTarget(
	text: string,
): Result<DarwinTarget, string> {
	return match (text) {
		"aarch64-macos" => Result.ok(DarwinTarget.Arm64),
		"x86_64-macos" => Result.ok(DarwinTarget.X64),
		_ => Result.err("unsupported Darwin target: " + text),
	};
}

export function darwinConfigName(target: DarwinTarget): string {
	return darwinTargetName(target) + ".cfg";
}

export function renderDarwinConfig(target: DarwinTarget): string {
	const arch = target == DarwinTarget.Arm64 ? "aarch64" : "x86_64";
	return [
		"--target=" + arch + "-apple-macos" + MINIMUM_MACOS_VERSION,
		"-isysroot <CFGDIR>/" + DARWIN_SYSROOT,
		"--ld-path=<CFGDIR>/" + DARWIN_ENGINE_RELATIVE + "/bin/ld64.lld",
	].join("\n") + "\n";
}

export function selectDarwinTargets(
	names: string[],
): Result<DarwinTarget[], string> {
	if (names.length == 0) { return Result.ok(canonicalTargets()); }
	const requested: DarwinTarget[] = [];
	for (const name of names) {
		const target = try parseDarwinTarget(name);
		for (const seen of requested) {
			if (seen == target) {
				return Result.err("duplicate Darwin target: " + name);
			}
		}
		requested.push(target);
	}
	const chosen: DarwinTarget[] = [];
	for (const target of canonicalTargets()) {
		for (const wanted of requested) {
			if (wanted == target) { chosen.push(target); }
		}
	}
	return Result.ok(chosen);
}
