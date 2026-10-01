import { compileToC } from "../helpers";

function functionBody(code: string, name: string): string {
	for (const line of code.split("\n")) {
		const at = line.indexOf(" " + name);
		if (at < 0 || !line.endsWith(" {") || line.indexOf("(", at) < 0) continue;
		const start = code.indexOf(line + "\n");
		const end = code.indexOf("\n}", start);
		if (end >= 0) return code.slice(start, end);
	}
	return "";
}

function occurrences(body: string, name: string): int32 {
	return (body.split(name + "(").length - 1) as int32;
}

struct Transfer {
	name: string;
	increfs: int32;
}

test "casts and assertions preserve borrowed versus owned reference provenance" {
	const result = compileToC(`
class Thing { value: int32 = 0; }
interface Box { p: Thing | null; q: Thing; }
extern function makeThing(): Thing from "makeThing";
export function returnField(b: Box): Thing { return b.q as unknown as Thing; }
export function returnCall(): Thing { return makeThing() as unknown as Thing; }
export function returnParam(t: Thing): Thing { return t as unknown as Thing; }
export function sinkAsserted(b: Box, xs: Thing[]): void { xs.push(b.p!); }
export function sinkCast(b: Box, xs: Thing[]): void { xs.push(b.q as Thing); }
export function sinkBare(b: Box, xs: Thing[]): void { xs.push(b.q); }
export function sinkParam(t: Thing | null, xs: Thing[]): void { xs.push(t!); }
`);
	assert result.ok, result.ok ? "" : result.error;
	const transfers: Transfer[] = [
		{ name: "returnField", increfs: 1 },
		{ name: "returnCall", increfs: 0 },
		{ name: "returnParam", increfs: 1 },
		{ name: "sinkAsserted", increfs: 1 },
		{ name: "sinkCast", increfs: 1 },
		{ name: "sinkBare", increfs: 1 },
		{ name: "sinkParam", increfs: 1 },
	];
	for (const transfer of transfers) {
		const body = functionBody(result.value, transfer.name);
		assert body != "", transfer.name + " definition";
		assert occurrences(body, "msIncref") == transfer.increfs, transfer.name;
	}
}

function catchBindings(code: string): string[] {
	const names: string[] = [];
	for (const line of code.split("\n")) {
		const assignment = line.indexOf(" = (");
		if (assignment < 0 || !line.contains("*)") || !line.endsWith("msCurrException;")) continue;
		const declaration = line.slice(0, assignment).trim();
		names.push(declaration.slice(declaration.lastIndexOf(" ") + 1, declaration.length));
	}
	return names;
}

test "shadowed catch bindings each release their own exception exactly once" {
	for (const depth of [2, 3]) {
		let nested = "out = e.message;";
		for (let level = 0; level < depth; level += 1) {
			nested = `try { boom("${level}"); } catch (e) { ${nested} }`;
			if (level + 1 < depth) nested += "out = out + e.message;";
		}
		const result = compileToC(`function boom(m: string): void { throw new Error(m); } export function read(): string { let out = ""; ${nested} return out; }`);
		assert result.ok, result.ok ? "" : result.error;
		const body = functionBody(result.value, "read");
		const names = catchBindings(body);
		assert names.length == depth, "catch depth " + depth.toString();
		for (let i = 0; i < names.length; i += 1) {
			assert body.split(`msDecref(${names[i]});`).length - 1 == 1, names[i];
			for (let j = i + 1; j < names.length; j += 1) assert names[i] != names[j], "catch symbol identity";
		}
	}
}
