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

function aliasingHub(reexport: string): MapEntry[] {
	return [
		{ entryPath: "src/a.ms", entrySource: `export struct R { id: int32 }
export function text(this r: R): string { return "t" + r.id.toString(); }
export enum Kind { A, B }
` },
		{ entryPath: "src/hub.ms", entrySource: `import { R, text as labelText } from "./a";
${reexport}
export function viaAlias(r: R): string { return r.labelText(); }
` },
	];
}

test "extensionImportUse: an extension imported under its own name stays callable after a module that aliases it and re-exports from its source" {
	for (const reexport of ["export { Kind } from \"./a\";", "export * from \"./a\";"]) {
		const entries = aliasingHub(reexport);
		entries.push({ entryPath: "src/main.ms", entrySource: `import { viaAlias } from "./hub";
import { R, text } from "./a";
const r: R = { id: 1 };
console.log(r.text() + viaAlias(r));
` });
		const messages = checkProjectDiagnostics(entries, "src/main.ms");
		assert occurrences(messages, "Property 'text' does not exist") == 0, reexport + "\n" + messages.join("\n");
	}
}

test "extensionImportUse: a local alias of an extension does not reach the modules importing the aliasing module" {
	const entries = aliasingHub("export { Kind } from \"./a\";");
	entries.push({ entryPath: "src/main.ms", entrySource: `import { viaAlias } from "./hub";
import { R } from "./a";
const r: R = { id: 1 };
console.log(r.labelText() + viaAlias(r));
` });
	const messages = checkProjectDiagnostics(entries, "src/main.ms");
	assert occurrences(messages, "Property 'labelText' does not exist") == 1, messages.join("\n");
}
