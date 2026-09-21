import { DepsSection, PackageSection } from "../buildConfig";

export function reservedCommands(): string[] {
	return [
		"help", "version", "build", "run", "test", "check", "fmt", "init", "clean", "lsp",
		"upgrade", "x", "add", "remove", "install", "update", "publish", "login", "logout",
		"whoami", "org", "dump-tokens", "dump-ast", "pipeline",
	];
}

export function isReservedCommand(cmd: string): boolean {
	for (const r of reservedCommands()) {
		if (r == cmd) return true;
	}
	return false;
}

export function commandNameError(cmd: string): string {
	if (cmd.byteLength == 0) return "a command name cannot be empty";
	const first = cmd.byteAt(0);
	if (first < "a".code || first > "z".code) {
		return `command '${cmd}': must start with a lowercase letter`;
	}
	let i = 1;
	while (i < cmd.byteLength) {
		const c = cmd.byteAt(i);
		const ok = (c >= "a".code && c <= "z".code) || (c >= "0".code && c <= "9".code) || c == "-".code;
		if (!ok) return `command '${cmd}': only lowercase letters, digits and '-' are allowed`;
		i = i + 1;
	}
	if (cmd.charAt(cmd.byteLength - 1) == "-") return `command '${cmd}': cannot end with '-'`;
	if (isReservedCommand(cmd)) return `command '${cmd}': shadows the msc subcommand of the same name`;
	return "";
}

export function commandEntryError(cmd: string, entry: string): string {
	if (entry.length == 0) return `command '${cmd}': needs an entry path`;
	if (entry.charAt(0) == "/" || entry.contains(":\\") || entry.contains("\\")) {
		return `command '${cmd}': entry '${entry}' must be a relative path inside the package`;
	}
	if (entry.contains("..")) {
		return `command '${cmd}': entry '${entry}' cannot leave the package with '..'`;
	}
	if (!entry.endsWith(".ms")) {
		return `command '${cmd}': entry '${entry}' must be a .ms file`;
	}
	return "";
}

export function validateBin(bin: DepsSection): string[] {
	const errors: string[] = [];
	let i = 0;
	while (i < bin.keys.length) {
		const cmd = bin.keys[i];
		const nameErr = commandNameError(cmd);
		if (nameErr != "") {
			errors.push(nameErr);
		} else {
			const entryErr = commandEntryError(cmd, bin.values[i]);
			if (entryErr != "") errors.push(entryErr);
		}
		let j = 0;
		while (j < i) {
			if (bin.keys[j] == cmd) errors.push(`command '${cmd}': declared twice in package.bin`);
			j = j + 1;
		}
		i = i + 1;
	}
	return errors;
}

export function binEntryFor(pkg: PackageSection, cmd: string): string {
	let i = 0;
	while (i < pkg.bin.keys.length) {
		if (pkg.bin.keys[i] == cmd) return pkg.bin.values[i];
		i = i + 1;
	}
	return "";
}

test "a plain command name passes" {
	assert commandNameError("ion-generate") == "";
	assert commandNameError("gen2") == "";
}

test "a command name that shadows an msc subcommand is rejected" {
	assert commandNameError("build") != "";
	assert commandNameError("x") != "";
	assert commandNameError("whoami") != "";
}

test "every reserved command is rejected" {
	for (const r of reservedCommands()) {
		assert commandNameError(r) != "";
	}
}

test "a command name with bad characters is rejected" {
	assert commandNameError("") != "";
	assert commandNameError("Gen") != "";
	assert commandNameError("2fast") != "";
	assert commandNameError("my_cmd") != "";
	assert commandNameError("my/cmd") != "";
	assert commandNameError("trailing-") != "";
}

test "an entry must be a relative .ms path inside the package" {
	assert commandEntryError("c", "tooling/cli.ms") == "";
	assert commandEntryError("c", "") != "";
	assert commandEntryError("c", "/abs/cli.ms") != "";
	assert commandEntryError("c", "../outside/cli.ms") != "";
	assert commandEntryError("c", "tooling\\cli.ms") != "";
	assert commandEntryError("c", "tooling/cli") != "";
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
