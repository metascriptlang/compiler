// E2E: Control Flow → C output
// Wrapped in functions that are called from top-level.

import { compileToC } from "../helpers";


test "E2E C: if/else" {
	const src = "function f(x: number): number {\n  if (x > 0) { return 1; } else { return 0; }\n}\nconst r = f(5);";
	const c = compileToC(src);
	assert c.ok;
	// Codegen uses goto-based control flow, not structured if/else
	assert c.value.contains("return 1");
	assert c.value.contains("return 0");
}

test "E2E C: while loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  while (i < 10) { i = i + 1; }\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("while (");
}

test "E2E C: match lowers to if" {
	const src = "function f(x: number): number {\n  return match (x) {\n    1 => 10,\n    2 => 20,\n    _ => 0,\n  };\n}\nconst r = f(1);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("if (");
}

test "E2E C: return value" {
	const src = "function f(): number { return 42; }\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("return 42");
}

test "E2E C: for-of loop" {
	const src = "function sum(arr: number[]): number {\n  let s: number = 0;\n  for (const x of arr) { s = s + x; }\n  return s;\n}\nconst r = sum([1, 2, 3]);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("while (");
}

test "E2E C: do-while loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  do { i = i + 1; } while (i < 5);\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("do {");
	assert c.value.contains("while (");
}

test "E2E C: break in loop" {
	const src = "function f(): number {\n  let i: number = 0;\n  while (i < 100) {\n    if (i === 5) { break; }\n    i = i + 1;\n  }\n  return i;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("break;");
}

test "E2E C: continue in loop" {
	const src = "function f(): number {\n  let s: number = 0;\n  let i: number = 0;\n  while (i < 5) {\n    i = i + 1;\n    if (i === 3) { continue; }\n    s = s + i;\n  }\n  return s;\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("continue;");
}

test "E2E C: match or-patterns" {
	const src = "function f(x: number): number {\n  return match (x) {\n    1 | 2 => 10,\n    3 => 30,\n    _ => 0,\n  };\n}\nconst r = f(1);";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("||");
}

// KNOWN ISSUE: match arm bindings (bare identifiers as captures) fail in pipeline.
// Checker or validator rejects: "n => n + 1" where n is a binding.
// test "E2E C: match with binding" {
// 	const src = "function f(x: number): number {\n  return match (x) {\n    0 => 100,\n    n => n + 1,\n  };\n}\nconst r = f(5);";
// 	const c = compileToC(src);
// 	check(c.ok);
// }

test "E2E C: try/catch" {
	const src = "function f(): number {\n  try { return 1; } catch (e) { return 0; }\n}\nconst r = f();";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("__catch_");
}

test "E2E C: throw statement" {
	const src = "function f(): void { throw \"error\"; }\ntry { f(); } catch (e) { }\nconst x: number = 1;";
	const c = compileToC(src);
	assert c.ok;
	assert c.value.contains("msCurrException = (msException*)(");
}

const forOfDecls = `
struct Node { children: Vec<int32>; flag: int32; }
struct Tree { nodes: Vec<Node>; }
struct Deep { trees: Vec<Tree>; }
class Box { n: int32 = 1; }
class Holder { items: Box[] = []; }
function boxes(): Box[] { return [new Box(), new Box()]; }
`;

function emittedBody(src: string, fn: string): string {
	const c = compileToC(forOfDecls + src);
	if (!c.ok) throw new Error(c.error);
	const start = c.value.indexOf(`${fn}__`, c.value.indexOf(`${fn}__`) + 1);
	return c.value.slice(start, c.value.indexOf("\n}\n", start));
}

test "E2E C: a for-of over a value path written through its root iterates in place" {
	const cases: string[][] = [
		["walk", `
function walk(ref t: Tree, i: int32): int32 {
	let sum: int32 = 0;
	for (const c of t.nodes[i].children) { t.nodes[c].flag = 1; sum = sum + c; }
	return sum;
}
let t: Tree = { nodes: [{ children: [1], flag: 0 }, { children: [], flag: 0 }] };
console.log(walk(t, 0));
`],
		["row", `
function row(i: int32): int32 {
	let g: Vec<Vec<int32>> = [[1, 2, 3], [4, 5]];
	let sum: int32 = 0;
	for (const c of g[i]) { g[1][0] = c; sum = sum + c; }
	return sum;
}
console.log(row(0));
`],
		["deep", `
function deep(ref d: Deep, i: int32, j: int32): int32 {
	let sum: int32 = 0;
	for (const c of d.trees[i].nodes[j].children) { d.trees[i].nodes[c].flag = 2; sum = sum + c; }
	return sum;
}
let d: Deep = { trees: [{ nodes: [{ children: [0], flag: 0 }] }] };
console.log(deep(d, 0, 0));
`],
	];
	for (const c of cases) assert !emittedBody(c[1], c[0]).contains("msArrayCopy"), c[0];
}

test "E2E C: a for-of binding borrows each element of the array the loop holds" {
	const cases: string[][] = [
		["sumCall", `
function sumCall(): int32 {
	let s: int32 = 0;
	for (const b of boxes()) s = s + b.n;
	return s;
}
console.log(sumCall());
`],
		["sumField", `
function sumField(h: Holder): int32 {
	let s: int32 = 0;
	for (const b of h.items) s = s + b.n;
	return s;
}
console.log(sumField(new Holder()));
`],
		["sumSkip", `
function sumSkip(): int32 {
	let s: int32 = 0;
	for (const b of boxes()) {
		if (b.n == 0) continue;
		s = s + b.n;
	}
	return s;
}
console.log(sumSkip());
`],
	];
	for (const c of cases) assert !emittedBody(c[1], c[0]).contains("msIncref"), c[0];
}
