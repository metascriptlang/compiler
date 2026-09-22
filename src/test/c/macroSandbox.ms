import { cacheRoot } from "../../compiler/package/cache";
import { normalize } from "std/fs/path";
import { checkProjectDiagnostics, MapEntry } from "../helpers";

function moduleImportPath(path: string): string {
	return path.endsWith(".ms") ? path.slice(0, path.length - 3) : path;
}

function hasMessage(messages: string[], text: string): boolean {
	for (const message of messages) {
		if (message.indexOf(text, 0) >= 0) return true;
	}
	return false;
}

function dependencyMacroDiagnostics(name: string, source: string): string[] {
	const depPath = normalize(cacheRoot() + `/extracted/${name}@1.0.0/index.ms`);
	const mainPath = normalize(cacheRoot() + `-project/${name}/main.ms`);
	const entries: MapEntry[] = [
		{ entryPath: depPath, entrySource: source },
		{ entryPath: mainPath, entrySource: `import { probe } from "${moduleImportPath(depPath)}";\nconst value = probe(1);\n` },
	];
	return checkProjectDiagnostics(entries, mainPath);
}

test "cached dependency macro can read files" {
	const messages = dependencyMacroDiagnostics("sandbox-read", `extern function msFsExists(path: string): number;
export macro probe(value) {
	if (msFsExists("README.md") == 0) return value;
	return value;
}
`);
	assert messages.length == 0;
}

test "cached dependency macro cannot write files" {
	const messages = dependencyMacroDiagnostics("sandbox-write", `extern function msFsWriteFileMode(path: string, content: string, mode: string): number;
export macro probe(value) {
	msFsWriteFileMode("/tmp/msc-sandbox-test-write", "owned", "wb");
	return value;
}
`);
	assert hasMessage(messages, "Restricted dependency compile-time code");
	assert hasMessage(messages, "host function 'msFsWriteFileMode'");
}

test "cached dependency macro cannot read environment" {
	const messages = dependencyMacroDiagnostics("sandbox-env", `extern function msProcessGetEnv(name: string): string;
export macro probe(value) {
	if (msProcessGetEnv("HOME") == "") return value;
	return value;
}
`);
	assert hasMessage(messages, "host function 'msProcessGetEnv'");
}

test "cached dependency macro cannot execute processes" {
	const messages = dependencyMacroDiagnostics("sandbox-exec", `extern function msProcessExecFile(path: string, args: string[]): number;
export macro probe(value) {
	msProcessExecFile("echo", []);
	return value;
}
`);
	assert hasMessage(messages, "host function 'msProcessExecFile'");
}

test "project-local macro keeps full host access" {
	const macroPath = normalize(cacheRoot() + "-project/local/macro.ms");
	const mainPath = normalize(cacheRoot() + "-project/local/main.ms");
	const entries: MapEntry[] = [
		{ entryPath: macroPath, entrySource: `extern function msProcessPlatform(): string;
export macro probe(value) {
	msProcessPlatform();
	return value;
}
` },
		{ entryPath: mainPath, entrySource: `import { probe } from "${moduleImportPath(macroPath)}";\nconst value = probe(1);\n` },
	];
	const messages = checkProjectDiagnostics(entries, mainPath);
	assert messages.length == 0;
}
