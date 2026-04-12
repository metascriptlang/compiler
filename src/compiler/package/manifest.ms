// Manifest — edit build.ms deps section.
// Uses text-level insertion (proven in C backend) + fmt normalization.

import { exists, readFile, writeFile } from "std/fs";
import { PackageSection, DepsSection, loadBuildConfig } from "../buildConfig";

export function readManifest(buildPath: string): { package: PackageSection, deps: DepsSection, devDeps: DepsSection, valid: boolean } {
	const cfg = loadBuildConfig(buildPath, false);
	return { package: cfg.package, deps: cfg.deps, devDeps: cfg.devDeps, valid: cfg.valid };
}

// --- String helpers ---

function findStr(content: string, needle: string, from: number): number {
	let i = from;
	while (i <= content.length - needle.length) {
		let match = true;
		let j = 0;
		while (j < needle.length) {
			if (content.charAt(i + j) !== needle.charAt(j)) { match = false; j = needle.length; }
			j = j + 1;
		}
		if (match) return i;
		i = i + 1;
	}
	return -1;
}

function findClosingBrace(content: string, openPos: number): number {
	let depth = 0;
	let i = openPos;
	while (i < content.length) {
		if (content.charAt(i) === "{") depth = depth + 1;
		if (content.charAt(i) === "}") {
			depth = depth - 1;
			if (depth === 0) return i;
		}
		i = i + 1;
	}
	return -1;
}

// --- Public API ---

export function addDepToManifest(buildPath: string, name: string, version: string, scope: string): boolean {
	if (!exists(buildPath)) return false;
	const content = try readFile(buildPath) catch "";
	if (content === "") return false;

	const quotedName = "\"" + name + "\"";
	const newEntry = quotedName + ": \"" + version + "\"";

	const blockKey = scope + ":";
	const blockStart = findStr(content, blockKey, 0);

	if (blockStart >= 0) {
		let bracePos = blockStart + blockKey.length;
		while (bracePos < content.length && content.charAt(bracePos) !== "{") bracePos = bracePos + 1;
		if (bracePos >= content.length) return false;

		const closeBrace = findClosingBrace(content, bracePos);
		if (closeBrace < 0) return false;

		// Check if dep already exists — update version
		const nameIdx = findStr(content, quotedName, bracePos);
		if (nameIdx >= 0 && nameIdx < closeBrace) {
			let valQuote1 = nameIdx + quotedName.length;
			while (valQuote1 < closeBrace && content.charAt(valQuote1) !== "\"") valQuote1 = valQuote1 + 1;
			let valQuote2 = valQuote1 + 1;
			while (valQuote2 < closeBrace && content.charAt(valQuote2) !== "\"") valQuote2 = valQuote2 + 1;
			const updated = content.slice(0, valQuote1 + 1) + version + content.slice(valQuote2, content.length);
			return writeFile(buildPath, updated).ok;
		}

		// Insert new entry
		const blockInner = content.slice(bracePos + 1, closeBrace).trim();
		let newContent = "";
		if (blockInner === "") {
			newContent = content.slice(0, bracePos + 1) + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		} else {
			let lastChar = closeBrace - 1;
			while (lastChar > bracePos && (content.charAt(lastChar) === " " || content.charAt(lastChar) === "\t" || content.charAt(lastChar) === "\n")) {
				lastChar = lastChar - 1;
			}
			const needsComma = lastChar > bracePos && content.charAt(lastChar) !== ",";
			const comma = needsComma ? "," : "";
			newContent = content.slice(0, lastChar + 1) + comma + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		}
		return writeFile(buildPath, newContent).ok;
	}

	// No deps block — insert one
	const exportIdx = findStr(content, "export default", 0);
	if (exportIdx < 0) return false;

	let configClose = exportIdx - 1;
	while (configClose > 0 && content.charAt(configClose) !== "}") configClose = configClose - 1;
	if (configClose <= 0) return false;

	let lastNonWs = configClose - 1;
	while (lastNonWs > 0 && (content.charAt(lastNonWs) === " " || content.charAt(lastNonWs) === "\t" || content.charAt(lastNonWs) === "\n")) {
		lastNonWs = lastNonWs - 1;
	}
	const needsComma = lastNonWs > 0 && content.charAt(lastNonWs) !== ",";
	const comma = needsComma ? "," : "";

	const insertion = comma + "\n\t" + scope + ": {\n\t\t" + newEntry + ",\n\t},\n";
	const newContent = content.slice(0, lastNonWs + 1) + insertion + content.slice(configClose, content.length);
	return writeFile(buildPath, newContent).ok;
}

export function removeDepFromManifest(buildPath: string, name: string): boolean {
	if (!exists(buildPath)) return false;
	const content = try readFile(buildPath) catch "";
	if (content === "") return false;

	const quotedName = "\"" + name + "\"";
	const idx = findStr(content, quotedName, 0);
	if (idx < 0) return false;

	let lineStart = idx;
	while (lineStart > 0 && content.charAt(lineStart - 1) !== "\n") lineStart = lineStart - 1;
	let lineEnd = idx;
	while (lineEnd < content.length && content.charAt(lineEnd) !== "\n") lineEnd = lineEnd + 1;

	const newContent = content.slice(0, lineStart) + content.slice(lineEnd + 1, content.length);
	return writeFile(buildPath, newContent).ok;
}

// --- Tests ---

test "addDepToManifest creates deps block" {
	const path = "/tmp/test-manifest-add.ms";
	writeFile(path, "const config = {\n\tentry: \"./src/index\",\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "cool-json", "1.2.3", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"cool-json\": \"1.2.3\"");
	assert content.contains("deps:");
}

test "addDepToManifest adds to existing block" {
	const path = "/tmp/test-manifest-add2.ms";
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "bar", "2.0.0", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"bar\": \"2.0.0\"");
	assert content.contains("\"foo\": \"1.0.0\"");
}

test "addDepToManifest updates existing dep" {
	const path = "/tmp/test-manifest-add3.ms";
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "foo", "2.0.0", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.contains("\"foo\": \"2.0.0\"");
	assert !content.contains("1.0.0");
}

test "removeDepFromManifest removes dep" {
	const path = "/tmp/test-manifest-rm.ms";
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t\t\"bar\": \"2.0.0\",\n\t},\n};\n\nexport default config;\n");
	const ok = removeDepFromManifest(path, "foo");
	assert ok;
	const content = try readFile(path) catch "";
	assert !content.contains("\"foo\"");
	assert content.contains("\"bar\": \"2.0.0\"");
}
