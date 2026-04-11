// Manifest — read/write build.ms deps section.
// String-level insertion for v1. Preserves formatting outside the modified block.

import { exists, readFile, writeFile } from "std/fs";
import { PackageSection, DepsSection, loadBuildConfig } from "../buildConfig";

export function readManifest(buildPath: string): { package: PackageSection, deps: DepsSection, devDeps: DepsSection, valid: boolean } {
	const cfg = loadBuildConfig(buildPath, false);
	return { package: cfg.package, deps: cfg.deps, devDeps: cfg.devDeps, valid: cfg.valid };
}

// Find the balanced closing brace for an opening brace at position openPos.
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

// Find substring in content starting from `from`. Returns -1 if not found.
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

// Add a dependency to build.ms. Returns true on success.
export function addDepToManifest(buildPath: string, name: string, version: string, scope: string): boolean {
	if (!exists(buildPath)) return false;
	const content = try readFile(buildPath) catch "";
	if (content === "") return false;

	const quotedName = "\"" + name + "\"";
	const newEntry = quotedName + ": \"" + version + "\"";

	// Find the scope block (deps: { ... } or devDeps: { ... })
	const blockKey = scope + ":";
	const blockStart = findStr(content, blockKey, 0);

	if (blockStart >= 0) {
		// Find the opening { after "deps:"
		let bracePos = blockStart + blockKey.length;
		while (bracePos < content.length && content.charAt(bracePos) !== "{") bracePos = bracePos + 1;
		if (bracePos >= content.length) return false;

		const closeBrace = findClosingBrace(content, bracePos);
		if (closeBrace < 0) return false;

		// Check if already exists — update version
		const nameIdx = findStr(content, quotedName, bracePos);
		if (nameIdx >= 0 && nameIdx < closeBrace) {
			// Find the value string after "name": "
			let valQuote1 = nameIdx + quotedName.length;
			while (valQuote1 < closeBrace && content.charAt(valQuote1) !== "\"") valQuote1 = valQuote1 + 1;
			let valQuote2 = valQuote1 + 1;
			while (valQuote2 < closeBrace && content.charAt(valQuote2) !== "\"") valQuote2 = valQuote2 + 1;
			// Replace old value with new
			const updated = content.slice(0, valQuote1 + 1) + version + content.slice(valQuote2, content.length);
			const r = writeFile(buildPath, updated);
			return r.ok;
		}

		// Insert new entry — check if block is empty or has content
		const blockInner = content.slice(bracePos + 1, closeBrace).trim();
		let newContent = "";
		if (blockInner === "") {
			// Empty block: { } → { "name": "ver" }
			newContent = content.slice(0, bracePos + 1) + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		} else {
			// Non-empty: insert before closing brace with comma
			// Find last non-whitespace before closing brace
			let lastChar = closeBrace - 1;
			while (lastChar > bracePos && (content.charAt(lastChar) === " " || content.charAt(lastChar) === "\t" || content.charAt(lastChar) === "\n")) {
				lastChar = lastChar - 1;
			}
			const needsComma = lastChar > bracePos && content.charAt(lastChar) !== ",";
			const comma = needsComma ? "," : "";
			newContent = content.slice(0, lastChar + 1) + comma + "\n\t\t" + newEntry + ",\n\t" + content.slice(closeBrace, content.length);
		}
		const r = writeFile(buildPath, newContent);
		return r.ok;
	}

	// No deps block — insert one before the closing `};` of the config object
	// Find the config object's closing brace (last `}` before `export default`)
	const exportIdx = findStr(content, "export default", 0);
	if (exportIdx < 0) return false;

	// Walk backwards from export to find the closing }
	let configClose = exportIdx - 1;
	while (configClose > 0 && content.charAt(configClose) !== "}") configClose = configClose - 1;
	if (configClose <= 0) return false;

	// Walk back past whitespace to find the actual end of the last field
	let insertPoint = configClose;
	// Check if there's a comma before the closing brace
	let lastNonWs = configClose - 1;
	while (lastNonWs > 0 && (content.charAt(lastNonWs) === " " || content.charAt(lastNonWs) === "\t" || content.charAt(lastNonWs) === "\n")) {
		lastNonWs = lastNonWs - 1;
	}
	const needsComma = lastNonWs > 0 && content.charAt(lastNonWs) !== ",";
	const comma = needsComma ? "," : "";

	const insertion = comma + "\n\t" + scope + ": {\n\t\t" + newEntry + ",\n\t},\n";
	const newContent = content.slice(0, lastNonWs + 1) + insertion + content.slice(configClose, content.length);
	const r = writeFile(buildPath, newContent);
	return r.ok;
}

// Remove a dependency from build.ms.
export function removeDepFromManifest(buildPath: string, name: string): boolean {
	if (!exists(buildPath)) return false;
	const content = try readFile(buildPath) catch "";
	if (content === "") return false;

	const quotedName = "\"" + name + "\"";
	const idx = findStr(content, quotedName, 0);
	if (idx < 0) return false;

	// Find the full line and remove it
	let lineStart = idx;
	while (lineStart > 0 && content.charAt(lineStart - 1) !== "\n") lineStart = lineStart - 1;
	let lineEnd = idx;
	while (lineEnd < content.length && content.charAt(lineEnd) !== "\n") lineEnd = lineEnd + 1;

	const newContent = content.slice(0, lineStart) + content.slice(lineEnd + 1, content.length);
	const r = writeFile(buildPath, newContent);
	return r.ok;
}

// --- Inline tests ---

test "addDepToManifest creates deps block" {
	const path = "/tmp/test-manifest-add.ms";
	writeFile(path, "const config = {\n\tentry: \"./src/index\",\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "cool-json", "1.2.3", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.indexOf("\"cool-json\": \"1.2.3\"") >= 0;
	assert content.indexOf("deps:") >= 0;
}

test "addDepToManifest adds to existing block" {
	const path = "/tmp/test-manifest-add2.ms";
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "bar", "2.0.0", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.indexOf("\"bar\": \"2.0.0\"") >= 0;
	assert content.indexOf("\"foo\": \"1.0.0\"") >= 0;
}

test "addDepToManifest updates existing dep" {
	const path = "/tmp/test-manifest-add3.ms";
	writeFile(path, "const config = {\n\tdeps: {\n\t\t\"foo\": \"1.0.0\",\n\t},\n};\n\nexport default config;\n");
	const ok = addDepToManifest(path, "foo", "2.0.0", "deps");
	assert ok;
	const content = try readFile(path) catch "";
	assert content.indexOf("\"foo\": \"2.0.0\"") >= 0;
	assert content.indexOf("1.0.0") < 0;
}
