import { basename } from "std/fs";
import { CompilePlan } from "./compilerPlan";
import { ElfLinkItem, ElfLinkItemKind } from "./elfLinkPlan";

export struct RuntimeConfigSpec {
	clangTarget: string;
	linker: string;
	driverFlags: string[];
	sysroot: boolean;
}

export struct RuntimeConfigInput {
	target: string;
	directory: string;
	spec: RuntimeConfigSpec;
	compile: CompilePlan;
	items: ElfLinkItem[];
	includeDirectories: string[];
	engineRelative: string;
	llvmMajor: string;
}

function alphanumeric(byte: uint8): boolean {
	return (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
		(byte >= 97 && byte <= 122);
}

function punctuation(byte: uint8, allowed: string): boolean {
	for (const value of allowed.asBytes()) {
		if (value == byte) { return true; }
	}
	return false;
}

export function configLine(
	tokens: Readonly<Span<string>>,
): Result<string, string> {
	let result = "";
	for (let index: int64 = 0; index < tokens.length; index += 1) {
		const token = tokens[index];
		if (token == "") { return Result.err("config token is empty"); }
		for (const byte of token.asBytes()) {
			if (!alphanumeric(byte) && !punctuation(byte, "_.+=:/<>,@%-")) {
				return Result.err("config token " + String(index) +
					" would need quoting: " + token);
			}
		}
		if (index != 0) { result += " "; }
		result += token;
	}
	return Result.ok(result);
}

function plainName(path: string): Result<string, string> {
	if (path.indexOf("\0") >= 0) { return Result.err("input name contains NUL"); }
	const name = basename(path);
	if (name == "" || name == "." || name == "..") {
		return Result.err("unsupported input file name: " + name);
	}
	for (const byte of name.asBytes()) {
		if (!alphanumeric(byte) && !punctuation(byte, "_.+-")) {
			return Result.err("unsupported input file name: " + name);
		}
	}
	return Result.ok(name);
}

export function renderRuntimeConfig(
	input: RuntimeConfigInput,
): Result<string, string> {
	const compile = input.compile;
	const spec = input.spec;
	const directory = input.directory == "" ? input.target : input.directory;
	const engine = "<CFGDIR>/" + input.engineRelative;
	const target = spec.clangTarget == "" ? compile.target : spec.clangTarget;
	const lines: string[] = [];
	lines.push(try configLine(["-target", target]));
	if (spec.sysroot) {
		lines.push(try configLine(["--sysroot=<CFGDIR>/" + directory]));
	}
	if (compile.pic.length > 0) { lines.push(try configLine(compile.pic)); }
	for (const define of compile.defines) {
		lines.push(try configLine([define]));
	}
	lines.push("-nostdinc");
	lines.push(try configLine([
		"-isystem", engine + "/lib/clang/" + input.llvmMajor + "/include",
	]));
	for (const include of input.includeDirectories) {
		lines.push(try configLine([
			"-isystem", "<CFGDIR>/include/libc/" + include,
		]));
	}
	for (const flag of spec.driverFlags) { lines.push(try configLine([flag])); }
	lines.push(try configLine(["--ld-path=" + engine + "/bin/" + spec.linker]));
	lines.push(try configLine([
		"-Xlinker", "-L", "-Xlinker", "<CFGDIR>/" + directory,
	]));
	for (const item of input.items) {
		match (item.kind) {
			ElfLinkItemKind.Argument => {
				lines.push(try configLine(["-Xlinker", item.value]));
			},
			ElfLinkItemKind.InputPath => {
				const name = try plainName(item.value);
				lines.push(try configLine([
					"-Xlinker", "<CFGDIR>/" + directory + "/" + name,
				]));
			},
			ElfLinkItemKind.UserObject => {},
		}
	}
	return Result.ok(lines.join("\n") + "\n");
}

function linksLibrary(value: string): boolean {
	if (value.indexOf(" ") >= 0) { return false; }
	if (value == "--as-needed") { return true; }
	if (!value.startsWith("<CFGDIR>/")) { return false; }
	const name = basename(value);
	if (name.endsWith(".a")) { return true; }
	const shared = name.indexOf(".so");
	if (shared < 0) { return false; }
	for (const part of name.slice(shared + 3).split(".")) {
		if (part == "") { continue; }
		for (const byte of part.asBytes()) {
			if (byte < 48 || byte > 57) { return false; }
		}
	}
	return true;
}

// A config names no CPU: a -target-cpu or -target-feature given through -Xclang reaches the compiler after the
// driver's own, so it would override every -march and -mcpu of the build. The baseline is the driver's default.
export function withoutCpuPin(configText: string): string {
	const kept: string[] = [];
	for (const line of configText.split("\n")) {
		if (line == "" || line.startsWith("-Xclang -target-cpu ") ||
			line.startsWith("-Xclang -target-feature ")) { continue; }
		kept.push(line);
	}
	return kept.join("\n") + "\n";
}

export function runtimeLibrariesLast(configText: string): string {
	const leading: string[] = [];
	const trailing: string[] = [];
	for (const line of configText.split("\n")) {
		if (line == "") { continue; }
		if (line.startsWith("-Xlinker ") && linksLibrary(line.slice(9))) {
			trailing.push("$-Xlinker $" + line.slice(9));
		} else {
			leading.push(line);
		}
	}
	return leading.concat(trailing).join("\n") + "\n";
}
