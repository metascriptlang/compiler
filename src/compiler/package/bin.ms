import { DepsSection, PackageSection } from "../buildConfig";

const RESERVED_COMMANDS: string[] = [
	"help", "version", "build", "run", "test", "check", "fmt", "init", "clean", "lsp",
	"upgrade", "x", "add", "remove", "install", "update", "publish", "login", "logout",
	"whoami", "org", "dump-tokens", "dump-ast", "pipeline",
];

export function commandNameError(cmd: string): string | null {
	if (cmd.byteLength == 0) return "a command name cannot be empty";
	const first = cmd.byteAt(0);
	if (first < "a".code || first > "z".code) {
		return `command '${cmd}': must start with a lowercase letter`;
	}
	for (let i = 1; i < cmd.byteLength; i++) {
		const c = cmd.byteAt(i);
		const ok = (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "-".code;
		if (!ok) return `command '${cmd}': only lowercase letters, digits and '-' are allowed`;
	}
	if (cmd.charAt(cmd.byteLength - 1) == "-") return `command '${cmd}': cannot end with '-'`;
	if (RESERVED_COMMANDS.includes(cmd)) {
		return `command '${cmd}': shadows the msc subcommand of the same name`;
	}
	return null;
}

export function isAbsoluteEntry(entry: string): boolean {
	return entry.charAt(0) == "/" || entry.contains(":\\") || entry.contains("\\");
}

export function leavesPackage(entry: string): boolean {
	return entry.split("/").includes("..");
}

function commandEntryError(cmd: string, entry: string): string | null {
	if (entry.length == 0) return `command '${cmd}': needs an entry path`;
	if (isAbsoluteEntry(entry)) {
		return `command '${cmd}': entry '${entry}' must be a relative path inside the package`;
	}
	if (leavesPackage(entry)) {
		return `command '${cmd}': entry '${entry}' cannot leave the package with '..'`;
	}
	if (!entry.endsWith(".ms")) {
		return `command '${cmd}': entry '${entry}' must be a .ms file`;
	}
	return null;
}

export function validateBin(bin: DepsSection): string[] {
	const errors: string[] = [];
	for (let i = 0; i < bin.keys.length; i++) {
		const cmd = bin.keys[i];
		const nameErr = commandNameError(cmd);
		if (nameErr != null) {
			errors.push(nameErr);
		} else {
			const entryErr = commandEntryError(cmd, bin.values[i]);
			if (entryErr != null) errors.push(entryErr);
		}
		for (let j = 0; j < i; j++) {
			if (bin.keys[j] == cmd) errors.push(`command '${cmd}': declared twice in package.bin`);
		}
	}
	return errors;
}

export function binEntryFor(pkg: PackageSection, cmd: string): string {
	const i = pkg.bin.keys.indexOf(cmd);
	return i < 0 ? "" : pkg.bin.values[i];
}

test "a plain command name passes" {
	assert commandNameError("ion-generate") == null;
	assert commandNameError("gen2") == null;
}

test "a command name that shadows an msc subcommand is rejected" {
	assert commandNameError("build") != null;
	assert commandNameError("x") != null;
	assert commandNameError("whoami") != null;
}

test "every reserved command is rejected" {
	for (const r of RESERVED_COMMANDS) {
		assert commandNameError(r) != null;
	}
}

test "a command name with bad characters is rejected" {
	assert commandNameError("") != null;
	assert commandNameError("Gen") != null;
	assert commandNameError("2fast") != null;
	assert commandNameError("my_cmd") != null;
	assert commandNameError("my/cmd") != null;
	assert commandNameError("trailing-") != null;
}

test "an entry must be a relative .ms path inside the package" {
	assert commandEntryError("c", "tooling/cli.ms") == null;
	assert commandEntryError("c", "") != null;
	assert commandEntryError("c", "/abs/cli.ms") != null;
	assert commandEntryError("c", "../outside/cli.ms") != null;
	assert commandEntryError("c", "tooling\\cli.ms") != null;
	assert commandEntryError("c", "tooling/cli") != null;
}

test "a parent segment leaves the package and a dotted name does not" {
	assert leavesPackage("../a.ms");
	assert leavesPackage("src/../../a.ms");
	assert !leavesPackage("src/a..b.ms");
	assert commandEntryError("x", "src/a..b.ms") == null;
}

test "validateBin reports one error per bad entry" {
	const keys: string[] = ["good", "build"];
	const values: string[] = ["tooling/cli.ms", "tooling/other.ms"];
	const bin: DepsSection = { keys, values };
	const errors = validateBin(bin);
	assert errors.length == 1;
	assert errors[0].contains("build");
}

test "validateBin accepts a clean bin map" {
	const keys: string[] = ["ion-generate"];
	const values: string[] = ["tooling/generator/cli.ms"];
	const bin: DepsSection = { keys, values };
	assert validateBin(bin).length == 0;
}
