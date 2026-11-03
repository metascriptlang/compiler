import { compileToC } from "../helpers";

const TREE = `
class Node { kids: Node[] = []; tag: int32 = 0; }
function make(n: Node): Node[] { return n.kids.slice(0); }
export function constField(n: Node): int32 { const kids = n.kids; let s: int32 = 0; for (const k of kids) s = s + k.tag; return s; }
export function constCall(n: Node): int32 { const kids = make(n); let s: int32 = 0; for (const k of kids) s = s + k.tag; return s; }
const a = new Node(); a.kids.push(new Node());
console.log(constField(a) + constCall(a));
`;

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

function bodyOf(name: string): string {
	const result = compileToC(TREE);
	if (!result.ok) return result.error;
	return functionBody(result.value, name);
}

test "a for-of over a field array held by a const borrows the array and each element" {
	const body = bodyOf("constField");
	assert body != "", "constField has no definition";
	assert !body.contains("msIncref") && !body.contains("msDecref"), body;
	assert !body.contains("dollariter"), body;
}

test "a for-of over an owned array held by a const borrows each element" {
	const body = bodyOf("constCall");
	assert body != "", "constCall has no definition";
	assert !body.contains("msIncref"), body;
	assert !body.contains("dollariter"), body;
}

const SOURCES = `
class Item { tag: int32 = 0; }
export function viaParam(a: string[], rounds: int32): int32 { let n: int32 = 0; for (let k = 0; k < rounds; k++) { for (const t of a) n += t.length as int32; } return n; }
export function viaLet(src: string[], rounds: int32): int32 { let a = src; let n: int32 = 0; for (let k = 0; k < rounds; k++) { for (const t of a) n += t.length as int32; } return n; }
export function viaForVar(rows: string[][]): int32 { let n: int32 = 0; for (const row of rows) { for (const t of row) n += t.length as int32; } return n; }
export function viaItems(a: Item[], rounds: int32): int32 { let n: int32 = 0; for (let k = 0; k < rounds; k++) { for (const t of a) n += t.tag; } return n; }
export function reassigned(a: string[], b: string[]): int32 { let n: int32 = 0; for (let k = 0; k < 2; k++) { for (const t of a) { n += t.length as int32; a = b; } } return n; }
let ticks = 0;
function tick(): void { ticks += 1; }
export function viaRefParam(ref a: string[], rounds: int32): int32 { let n: int32 = 0; for (let k = 0; k < rounds; k++) { for (const t of a) { tick(); n += t.length as int32; } } return n; }
let held: string[] = ["a"];
console.log(viaParam(["a"], 1), viaLet(["a"], 1), viaForVar([["a"]]), viaItems([new Item()], 1), reassigned(["a"], ["bb"]), viaRefParam(held, 1));
`;

function sourceBody(name: string): string {
	const result = compileToC(SOURCES);
	if (!result.ok) return result.error;
	return functionBody(result.value, name);
}

test "a nested for-of over a string array held by a parameter nothing assigns copies no element" {
	const body = sourceBody("viaParam");
	assert body != "", "viaParam has no definition";
	assert !body.contains("msStringCopy"), body;
	assert !body.contains("dollariter"), body;
}

test "a nested for-of over a string array held by a let nothing assigns copies no element" {
	const body = sourceBody("viaLet");
	assert body != "", "viaLet has no definition";
	assert !body.contains("msStringCopy"), body;
	assert !body.contains("dollariter"), body;
}

test "a nested for-of over the string array an outer for-of binds reads the binding with no temp" {
	const body = sourceBody("viaForVar");
	assert body != "", "viaForVar has no definition";
	assert !body.contains("dollariter"), body;
}

test "a nested for-of over a class array held by a parameter counts no reference" {
	const body = sourceBody("viaItems");
	assert body != "", "viaItems has no definition";
	assert !body.contains("msIncref") && !body.contains("msDecref"), body;
	assert !body.contains("dollariter"), body;
}

test "a for-of whose body assigns the array variable keeps the array it started with" {
	const body = sourceBody("reassigned");
	assert body != "", "reassigned has no definition";
	assert body.contains("dollariter"), body;
}

test "a nested for-of over the array it started with borrows each element from it" {
	const body = sourceBody("reassigned");
	assert body != "", "reassigned has no definition";
	assert !body.contains("msStringCopy"), body;
}

test "a nested for-of over a ref parameter keeps the array it started with and copies no element across a scalar write" {
	const body = sourceBody("viaRefParam");
	assert body != "", "viaRefParam has no definition";
	assert body.contains("dollariter"), body;
	assert !body.contains("msStringCopy"), body;
}
