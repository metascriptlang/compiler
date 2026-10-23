// Manifest — edit build.ms deps section.
// Uses text-level insertion (proven in C backend) + fmt normalization.

import { exists, readFile, writeFile, join } from "std/fs";
import { env } from "std/process";
import { PackageSection, DepsSection, loadBuildConfig } from "../buildConfig";

// Test scratch dir — the OS temp dir WITHOUT importing std/os: its C-header
// (@compile of runtime/os.h) drags system includes into these test TUs.
// Windows sets TMP/TEMP; POSIX falls back to /tmp (same as std/os tmpDir).
function testTmpDir(): string {
	const t = env.get("TMP");
	if (t != "") return t;
	const t2 = env.get("TEMP");
	if (t2 != "") return t2;
	const t3 = env.get("TMPDIR");
	if (t3 != "") return t3;
	return "/tmp";
}

export function readManifest(buildPath: string): { package: PackageSection, deps: DepsSection, devDeps: DepsSection, valid: boolean } {
	const cfg = loadBuildConfig(buildPath, false);
	return { package: cfg.package, deps: cfg.deps, devDeps: cfg.devDeps, valid: cfg.valid };
}

// --- String helpers ---

function findClosingBrace(content: string, openPos: int32): int32 {
	let depth = 0;
	let i = openPos;
	while (i < content.length) {
		if (content.charAt(i) == "{") depth = depth + 1;
		if (content.charAt(i) == "}") {
			depth = depth - 1;
			if (depth == 0) return i;
		}
		i = i + 1;
	}
	return -1;
}

export enum ManifestError {
	NoFile,
	Unreadable,
	NoBlockBrace,
	Unbalanced,
	NoExport,
	NoConfigObject,
	NotFound,
	Write,
}

export function manifestErrorMessage(e: ManifestError): string {
	return match (e) {
		ManifestError.NoFile => "build.ms not found",
		ManifestError.Unreadable => "build.ms is empty or unreadable",
		ManifestError.NoBlockBrace => "the dependency block has no opening brace",
		ManifestError.Unbalanced => "the dependency block has no closing brace",
		ManifestError.NoExport => "build.ms has no `export default`",
		ManifestError.NoConfigObject => "no config object before `export default`",
		ManifestError.NotFound => "dependency not found in build.ms",
		ManifestError.Write => "failed to write build.ms",
	};
}

function loadManifest(buildPath: string): Result<string, ManifestError> {
	if (!exists(buildPath)) return Result.err(ManifestError.NoFile);
	const content = readFile(buildPath);
	if (!content.ok || content.value == "") return Result.err(ManifestError.Unreadable);
	return Result.ok(content.value);
}

function saveManifest(buildPath: string, content: string): Result<void, ManifestError> {
	if (!writeFile(buildPath, content).ok) return Result.err(ManifestError.Write);
	return Result.ok(null);
}

// --- Public API ---

export function addDepToManifest(buildPath: string, name: string, version: string, scope: string): Result<void, ManifestError> {
	const content = try loadManifest(buildPath);

	const quotedName = "\"" + name + "\"";
	const newEntry = quotedName + ": \"" + version + "\"";

	const blockKey = scope + ":";
	const blockStart = content.indexOf(blockKey);

	if (blockStart >= 0) {
		let bracePos = blockStart + blockKey.length;
		while (bracePos < content.length && content.charAt(bracePos) != "{") bracePos = bracePos + 1;
		if (bracePos >= content.length) return Result.err(ManifestError.NoBlockBrace);

		const closeBrace = findClosingBrace(content, bracePos);
		if (closeBrace < 0) return Result.err(ManifestError.Unbalanced);

		// Check if dep already exists — update version
		const nameIdx = content.indexOf(quotedName, bracePos);
		if (nameIdx >= 0 && nameIdx < closeBrace) {
			let valQuote1 = nameIdx + quotedName.length;
			while (valQuote1 < closeBrace && content.charAt(valQuote1) != "\"") valQuote1 = valQuote1 + 1;
			let valQuote2 = valQuote1 + 1;
			while (valQuote2 < closeBrace && content.charAt(valQuote2) != "\"") valQuote2 = valQuote2 + 1;
			const updated = content.slice(0, valQuote1 + 1) + version + content.slice(valQuote2, content.length);
			return saveManifest(buildPath, updated);
		}

		// Insert new entry
		const blockInner = content.slice(bracePos + 1, closeBrace).trim();
		let newContent = "";
		if (blockInner == "") {
			newContent = content.slice(0, bracePos + 1) + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		} else {
			let lastChar = closeBrace - 1;
			while (lastChar > bracePos && (content.charAt(lastChar) == " " || content.charAt(lastChar) == "\t" || content.charAt(lastChar) == "\n")) {
				lastChar = lastChar - 1;
			}
			const needsComma = lastChar > bracePos && content.charAt(lastChar) != ",";
			const comma = needsComma ? "," : "";
			newContent = content.slice(0, lastChar + 1) + comma + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		}
		return saveManifest(buildPath, newContent);
	}

	// No deps block — insert one
	const exportIdx = content.indexOf("export default");
	if (exportIdx < 0) return Result.err(ManifestError.NoExport);

	let configClose = exportIdx - 1;
	while (configClose > 0 && content.charAt(configClose) != "}") configClose = configClose - 1;
	if (configClose <= 0) return Result.err(ManifestError.NoConfigObject);

	let lastNonWs = configClose - 1;
	while (lastNonWs > 0 && (content.charAt(lastNonWs) == " " || content.charAt(lastNonWs) == "\t" || content.charAt(lastNonWs) == "\n")) {
		lastNonWs = lastNonWs - 1;
	}
	const needsComma = lastNonWs > 0 && content.charAt(lastNonWs) != ",";
	const comma = needsComma ? "," : "";

	const insertion = comma + "\n\t" + scope + ": {\n\t\t" + newEntry + ",\n\t},\n";
	const newContent = content.slice(0, lastNonWs + 1) + insertion + content.slice(configClose, content.length);
	return saveManifest(buildPath, newContent);
}

export function removeDepFromManifest(buildPath: string, name: string): Result<void, ManifestError> {
	const content = try loadManifest(buildPath);

	const quotedName = "\"" + name + "\"";
	const idx = content.indexOf(quotedName);
	if (idx < 0) return Result.err(ManifestError.NotFound);

	let lineStart = idx;
	while (lineStart > 0 && content.charAt(lineStart - 1) != "\n") lineStart = lineStart - 1;
	let lineEnd = idx;
	while (lineEnd < content.length && content.charAt(lineEnd) != "\n") lineEnd = lineEnd + 1;

	const newContent = content.slice(0, lineStart) + content.slice(lineEnd + 1, content.length);
	return saveManifest(buildPath, newContent);
}

// --- Tests ---

test "addDepToManifest creates deps block" {
	const path = join(testTmpDir(), "test-manifest-add.ms");
	writeFile(path, "const config = {\n\tentry: \"./src/index\",\n};\n\nexport default config;\n");
	assert addDepToManifest(path, "cool-json", "1.2.3", "deps").ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"cool-json\": \"1.2.3\"");
	assert content.contains("deps:");
}

test "addDepToManifest adds to existing block" {
	const path = join(testTmpDir(), "test-manifest-add2.ms");
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	assert addDepToManifest(path, "bar", "2.0.0", "deps").ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"bar\": \"2.0.0\"");
	assert content.contains("\"foo\": \"1.0.0\"");
}

test "addDepToManifest updates existing dep" {
	const path = join(testTmpDir(), "test-manifest-add3.ms");
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	assert addDepToManifest(path, "foo", "2.0.0", "deps").ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"foo\": \"2.0.0\"");
	assert !content.contains("1.0.0");
}

test "removeDepFromManifest removes dep" {
	const path = join(testTmpDir(), "test-manifest-rm.ms");
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t\t\"bar\": \"2.0.0\",\n\t},\n};\n\nexport default config;\n");
	assert removeDepFromManifest(path, "foo").ok;
	const content = try readFile(path) catch "";
	assert !content.contains("\"foo\"");
	assert content.contains("\"bar\": \"2.0.0\"");
}

function addError(content: string): ManifestError {
	const path = join(testTmpDir(), "test-manifest-err.ms");
	writeFile(path, content);
	const r = addDepToManifest(path, "foo", "1.0.0", "deps");
	if (r.ok) return ManifestError.Write;
	return r.error;
}

test "a manifest edit says why it could not be made" {
	const missing = addDepToManifest("/nonexistent/build.ms", "foo", "1.0.0", "deps");
	assert !missing.ok;
	if (!missing.ok) assert missing.error == ManifestError.NoFile;
	assert addError("deps:") == ManifestError.NoBlockBrace;
	assert addError("const config = {\n\tdeps: {\n") == ManifestError.Unbalanced;
	assert addError("const config = {};\n") == ManifestError.NoExport;
	assert addError("export default config;\n") == ManifestError.NoConfigObject;
}

test "removing a dependency that is not declared is NotFound" {
	const path = join(testTmpDir(), "test-manifest-rm-missing.ms");
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	const r = removeDepFromManifest(path, "bar");
	assert !r.ok;
	if (!r.ok) assert r.error == ManifestError.NotFound;
}
