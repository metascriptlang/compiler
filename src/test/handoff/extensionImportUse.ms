import { checkProjectDiagnostics, MapEntry } from "../helpers";

function occurrences(messages: string[], text: string): int32 {
	let n = 0;
	for (const m of messages) {
		if (m.contains(text)) n += 1;
	}
	return n;
}

test "extensionImportUse: an imported extension a call picks over a std method counts as a use" {
	const entries: MapEntry[] = [
		{ entryPath: "src/b.ms", entrySource: `export function trim(this s: string): string { return "B:" + s; }
` },
		{ entryPath: "src/main.ms", entrySource: `import { trim } from "./b";
const s = " hello ";
console.log(s.trim());
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "'trim' is imported but never used") == 0, messages.join("\n");
}

test "extensionImportUse: an import named like the method a call picks still warns" {
	const entries: MapEntry[] = [
		{ entryPath: "src/paths.ms", entrySource: `export function join(parts: string[]): string { return parts.length.toString(); }
` },
		{ entryPath: "src/main.ms", entrySource: `import { join } from "./paths";
console.log(["a", "b"].join(","));
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "'join' is imported but never used") == 1, messages.join("\n");
}

test "extensionImportUse: calling one extension of an imported overload set counts as a use of the set" {
	const entries: MapEntry[] = [
		{ entryPath: "src/lib.ms", entrySource: `export function tag(n: int32): string { return \`n\${n}\`; }
export function tag(this s: string): string { return \`s\${s}\`; }
` },
		{ entryPath: "src/main.ms", entrySource: `import { tag } from "./lib";
console.log("x".tag());
` },
	];
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "'tag' is imported but never used") == 0, messages.join("\n");
}
