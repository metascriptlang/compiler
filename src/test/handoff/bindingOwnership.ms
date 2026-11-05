import { compileToC, compileToJSWithStd, checkProjectDiagnostics, compileProjectToCWithStd, MapEntry } from "../helpers";
import { checkModuleGraph } from "../../checker/orchestrator";
import { lookupModuleCtx } from "../../checker/instantiate";
import { Severity } from "../../checker/context";
import { ModuleGraph, findModule, ErrorSeverity } from "../../module/graph";
import { createMapProvider, loadModuleGraph } from "../../module/loader";
import { resetBuildState } from "../../compiler/buildSession";

test "bindingOwnership: explicit moves require ownership transfer rather than implicit copying" {
	const cases = [
		{ name: "explicit move that would copy is rejected", source: "\nclass Foo {\n\tx: int32 = 1;\n}\n\nexport function moveThenUse(): int32 {\n\tconst a = new Foo();\n\tlet b = new Foo();\n\tb = move a;\n\treturn a.x + b.x;\n}\n", expected: -1 },
		{ name: "explicit move on a last use still compiles", source: "\nclass Foo {\n\tx: int32 = 1;\n}\n\nexport function moveAtLastUse(): int32 {\n\tconst a = new Foo();\n\tlet b = new Foo();\n\tb = move a;\n\treturn b.x;\n}\n", expected: 0 },
		{ name: "moving an element read afterwards is rejected at the move", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst x = move arr[0];\n\treturn x.v + (arr[0] == null ? \"null\" : \"kept\");\n}\n", expected: -1 },
		{ name: "moving an owned element read afterwards is rejected at the move", source: "\nclass N { id: int32 = 0; }\nexport function run(): int32 {\n\tlet kids: Vec<Owned<N>> = [new N(), new N()];\n\tconst k = move kids[0];\n\treturn k.id + kids[0].id;\n}\n", expected: -1 },
		{ name: "moving a nested element out of a return is rejected", source: "\nexport function run(): string {\n\tconst grid: string[][] = [[\"a\" + String(1), \"b\"], [\"c\"]];\n\treturn move grid[0][1];\n}\n", expected: -1 },
		{ name: "moving an element into a sink argument out of a local dropped unread still compiles", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst out: Leaf[] = [];\n\tout.push(move arr[1]);\n\treturn out[0].v;\n}\n", expected: 0 },
		{ name: "moving an element into a sink argument and reading its local again is rejected", source: "\ninterface Leaf { v: string; }\nexport function run(): string {\n\tconst arr: Leaf[] = [{ v: \"a\" }, { v: \"b\" }];\n\tconst out: Leaf[] = [];\n\tout.push(move arr[1]);\n\treturn out[0].v + arr[0].v;\n}\n", expected: -1 },
		{ name: "moving a field still compiles", source: "\nclass H { f: string = \"\"; }\nexport function run(): string {\n\tconst h = new H();\n\th.f = \"x\" + String(1);\n\tconst t = move h.f;\n\treturn t + h.f;\n}\n", expected: 0 },
	];
	for (const item of cases) {
		const result = compileToC(item.source);
		assert result.ok == (item.expected == 0), item.name + (result.ok ? "" : ": " + result.error);
	}
}

function refusedOnBothBackends(source: string): string {
	let c: Result<string, string>;
	try { c = compileToC(source); } catch (e) { return "C threw: " + (e as Error).message; }
	let js: Result<string, string>;
	try { js = compileToJSWithStd(source); } catch (e) { return "JS threw: " + (e as Error).message; }
	if (c.ok || js.ok) return (c.ok ? "C compiled" : "C refused") + ", " + (js.ok ? "JS compiled" : "JS refused");
	return c.error + "\n" + js.error;
}

function keptOnBothBackends(source: string): string {
	let c: Result<string, string>;
	try { c = compileToC(source); } catch (e) { return "C threw: " + (e as Error).message; }
	let js: Result<string, string>;
	try { js = compileToJSWithStd(source); } catch (e) { return "JS threw: " + (e as Error).message; }
	return (c.ok ? "" : "C: " + c.error) + (js.ok ? "" : " JS: " + js.error);
}

test "bindingOwnership: a variable read after its move is refused on every backend" {
	const shapes = "class N { id: int32 = 1; }\nstruct P { x: int32; }\nfunction take(sink n: N): int32 { return n.id; }\n";
	const refused = [
		{ name: "a read after a move in one branch", body: "export function run(flag: boolean): int32 { const x = new N(); if (flag) take(move x); return x.id; }", variable: "x" },
		{ name: "a move in a loop body", body: "export function run(): int32 { const x = new N(); let s = 0; for (let i = 0; i < 2; i++) s += take(move x); return s; }", variable: "x" },
		{ name: "a move on one side of &&", body: "export function run(flag: boolean): int32 { const x = new N(); const ok = flag && take(move x) > 0; return ok ? x.id : 0; }", variable: "x" },
		{ name: "a later argument of the same call", body: "function both(sink a: N, b: N): int32 { return a.id + b.id; }\nexport function run(): int32 { const x = new N(); return both(move x, x); }", variable: "x" },
		{ name: "a write through the variable after its move", body: "class M { id: int32 = 1; other: int32 = 0; }\nfunction takeM(sink m: M): int32 { return m.id; }\nexport function run(): int32 { const x = new M(); x.other = takeM(move x); return 0; }", variable: "x" },
		{ name: "a Vec read after its move", body: "export function run(): int32 { const v: Vec<int32> = [1, 2]; const w = move v; return w.length + v.length; }", variable: "v" },
		{ name: "a POD struct read after its move", body: "export function run(): int32 { const a: P = { x: 7 }; const b = move a; return b.x + a.x; }", variable: "a" },
		{ name: "an int read after its move", body: "export function run(): int32 { let n: int32 = 5; const m = move n; return m + n; }", variable: "n" },
		{ name: "a read after a move that follows a for..of loop", body: "export function run(): int32 { const xs: Vec<int32> = [1, 2]; const x = new N(); let s = 0; for (const k of xs) s += k; const a = take(move x); return a + s + x.id; }", variable: "x" },
		{ name: "a for..of loop that reads the name in the next outer iteration", body: "export function run(): int32 { const xs: Vec<int32> = [1, 2]; const x = new N(); let s = 0; for (let i = 0; i < 2; i++) { for (const k of xs) s += k + x.id; s += take(move x); } return s; }", variable: "x" },
	];
	for (const item of refused) {
		const errors = refusedOnBothBackends(shapes + item.body);
		assert errors.split("cannot move '" + item.variable + "': variable is still used after this point").length == 3, item.name + ": " + errors;
	}
	const kept = [
		{ name: "a read in the branch that did not move", body: "export function run(flag: boolean): int32 { const x = new N(); return flag ? take(move x) : x.id; }" },
		{ name: "a variable assigned again before the read", body: "export function run(): int32 { let x = new N(); const a = take(move x); x = new N(); return a + x.id; }" },
		{ name: "a loop that assigns the variable again after the move", body: "export function run(): int32 { let x = new N(); let s = 0; for (let i = 0; i < 3; i++) { s += take(move x); x = new N(); } return s; }" },
		{ name: "a variable declared in the loop body", body: "export function run(): int32 { let s = 0; for (let i = 0; i < 3; i++) { const x = new N(); s += take(move x); } return s; }" },
		{ name: "a catch binding moved in a loop", body: "function boom(): int32 { throw new Error(\"b\"); }\nexport function run(): int32 { const kept: Error[] = []; for (let i = 0; i < 2; i++) { try { boom(); } catch (e) { kept.push(move e); } } return kept.length; }" },
		{ name: "a POD struct moved at its last read", body: "export function run(): int32 { const a: P = { x: 7 }; const b = move a; return b.x; }" },
		{ name: "a move after a for..of loop that reads the name", body: "export function run(): int32 { const xs: Vec<int32> = [1, 2]; const x = new N(); let s = 0; for (const k of xs) s += k + x.id; return s + take(move x); }" },
		{ name: "a Vec filled in a for..of loop and moved after it", body: "function takeVec(sink v: Vec<int32>): int32 { return v.length; }\nexport function run(): int32 { const xs: Vec<int32> = [1, 2]; let known: Vec<int32> = []; for (const k of xs) known.push(k); return takeVec(move known); }" },
	];
	for (const item of kept) {
		const errors = keptOnBothBackends(shapes + item.body);
		assert errors == "", item.name + ": " + errors;
	}
}

test "bindingOwnership: a read in a catch or a defer sees every move that can reach it" {
	const shapes = "class N { id: int32 = 1; }\nfunction take(sink n: N): int32 { return n.id; }\nfunction takeVec(sink v: Vec<int32>): int32 { return v.length; }\nfunction risky(): void { throw new Error(\"r\"); }\n";
	const refused = [
		{ name: "a throw after an if, read in the catch", body: "export function run(flag: boolean): string { const x = new Error(\"b\"); try { if (flag) console.log(\"f\"); throw move x; } catch (e) { return x.message; } }", variable: "x" },
		{ name: "a throw after a loop, read in the catch", body: "export function run(n: int32): string { const x = new Error(\"b\"); try { for (let i = 0; i < n; i++) console.log(\"i\"); throw move x; } catch (e) { return x.message; } }", variable: "x" },
		{ name: "a move in a branch before a call that throws", body: "export function run(flag: boolean): int32 { const x = new N(); try { if (flag) console.log(\"f\"); if (flag) take(move x); risky(); } catch (e) { return x.id; } return 0; }", variable: "x" },
		{ name: "a defer that reads a moved Vec", body: "export function run(): int32 { const x: Vec<int32> = [1, 2]; const n = takeVec(move x); defer console.log(x.length.toString()); return n; }", variable: "x" },
		{ name: "a defer that reads a moved class", body: "export function run(): int32 { const x = new N(); take(move x); defer console.log(x.id.toString()); return 0; }", variable: "x" },
	];
	for (const item of refused) {
		const errors = refusedOnBothBackends(shapes + item.body);
		assert errors.split("cannot move '" + item.variable + "': variable is still used after this point").length == 3, item.name + ": " + errors;
	}
	const kept = [
		{ name: "a throw whose catch reads another name", body: "export function run(): string { const x = new Error(\"b\"); const y = \"y\" + String(1); try { throw move x; } catch (e) { return y; } }" },
		{ name: "a defer of an inner block that ends before the move", body: "export function run(): int32 { const x: Vec<int32> = [1, 2]; { defer console.log(x.length.toString()); } return takeVec(move x); }" },
	];
	for (const item of kept) {
		const errors = keptOnBothBackends(shapes + item.body);
		assert errors == "", item.name + ": " + errors;
	}
}

test "bindingOwnership: a move of a name the function does not own is refused on every backend" {
	const shapes = "struct S { xs: Vec<int32>; }\nfunction grow(sink s: S): int32 { return s.xs.length; }\nfunction takeText(sink s: string): int32 { return s.length; }\n";
	const refused = [
		{ name: "a plain parameter", body: "export function run(s: S): int32 { return grow(move s); }", variable: "s", why: "it is a parameter" },
		{ name: "a plain string parameter", body: "export function run(s: string): int32 { return takeText(move s); }", variable: "s", why: "it is a parameter" },
		{ name: "a module-level binding", body: "let g: S = { xs: [1] };\nexport function run(): int32 { return grow(move g); }", variable: "g", why: "it is a module-level binding" },
		{ name: "a for-of element", body: "export function run(): int32 { const arr: S[] = [{ xs: [1] }]; let n = 0; for (const e of arr) n += grow(move e); return n; }", variable: "e", why: "it is a for..of element" },
	];
	for (const item of refused) {
		const errors = refusedOnBothBackends(shapes + item.body);
		assert errors.split("cannot move '" + item.variable + "': " + item.why).length == 3, item.name + ": " + errors;
	}
	const kept = [
		{ name: "a sink parameter", body: "export function run(sink s: S): int32 { return grow(move s); }" },
		{ name: "a constructor parameter", body: "class H { s: S; constructor(s: S) { this.s = move s; } }\nexport function run(): int32 { return new H({ xs: [1] }).s.xs.length; }" },
		{ name: "a local", body: "export function run(): int32 { const s: S = { xs: [1] }; return grow(move s); }" },
		{ name: "a module-level binding moved by top-level code", body: "let g: S = { xs: [1] };\nconst n = grow(move g);\nexport function run(): int32 { return n; }" },
	];
	for (const item of kept) {
		const errors = keptOnBothBackends(shapes + item.body);
		assert errors == "", item.name + ": " + errors;
	}
}

test "bindingOwnership: an owned local copied while it is still read is refused on every backend" {
	const shapes = "class N { id: int32 = 1; kids: Vec<Owned<N>> = []; }\n";
	const refused = [
		{ name: "a second owner bound while the first is read", body: "export function run(): int32 { const o: Owned<N> = new N(); const second: Owned<N> = o; return o.id + second.id; }", variable: "o" },
		{ name: "an owned local pushed in a loop", body: "export function run(): int32 { const root: Owned<N> = new N(); const a: Owned<N> = new N(); for (let i = 0; i < 2; i++) root.kids.push(a); return root.kids.length; }", variable: "a" },
	];
	for (const item of refused) {
		const errors = refusedOnBothBackends(shapes + item.body);
		assert errors.split("cannot copy '" + item.variable + "'").length == 3, item.name + ": " + errors;
	}
	const kept = [
		{ name: "the last read of an owned local", body: "export function run(): int32 { const root: Owned<N> = new N(); const a: Owned<N> = new N(); root.kids.push(a); return root.kids.length; }" },
		{ name: "an owned local read as a plain reference", body: "export function run(): int32 { const a: Owned<N> = new N(); const p: N = a; return a.id + p.id; }" },
	];
	for (const item of kept) {
		const errors = keptOnBothBackends(shapes + item.body);
		assert errors == "", item.name + ": " + errors;
	}
}

test "bindingOwnership: an explicit move out of a path needs a location the mover may write" {
	const shapes = "struct Node { kids: Vec<int32>; }\nstruct Tree { nodes: Vec<Node>; kids: Vec<int32>; }\nclass Box { readonly kids: Vec<int32> = []; }\n";
	const refused = [
		{ name: "a for-of element binding", body: "export function run(t: Tree): int32 { let n: int32 = 0; for (const node of t.nodes) { const k = move node.kids; n += k.length; } return n; }", refusal: "cannot mutate value-type loop variable 'node'" },
		{ name: "a value parameter", body: "export function run(t: Tree): int32 { const k = move t.kids; return k.length; }", refusal: "cannot mutate value-type parameter 't'" },
		{ name: "a const binding", body: "export function run(): int32 { const t: Tree = { nodes: [], kids: [1] }; const k = move t.kids; return k.length; }", refusal: "cannot write 't.kids' — 't' is const" },
		{ name: "a readonly field", body: "export function run(b: Box): int32 { const k = move b.kids; return k.length; }", refusal: "cannot assign to 'kids' because it is a read-only property" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains(item.refusal), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
	const kept = [
		{ name: "a const identifier", body: "export function run(): int32 { const v: Vec<int32> = [1]; const k = move v; return k.length; }" },
		{ name: "a let binding's field", body: "export function run(): int32 { let t: Tree = { nodes: [], kids: [1] }; const k = move t.kids; return k.length; }" },
		{ name: "a ref parameter's field", body: "export function run(ref t: Tree): int32 { const k = move t.kids; return k.length; }" },
		{ name: "an indexed element's field", body: "export function run(): int32 { let t: Tree = { nodes: [{ kids: [1] }], kids: [] }; const k = move t.nodes[0].kids; return k.length; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "bindingOwnership: an explicit move out of a field or element whose type has no default value is refused through a key, naming what to write instead, and kept out of a holder the routine created" {
	const shapes = "class Leaf { v: int32 = 7; }\nstruct Wrap { leaf: Leaf; }\nclass Holder { leaf: Leaf = new Leaf(); wrap: Wrap = { leaf: new Leaf() }; maybe: Leaf | null = new Leaf(); n: int32 = 1; s: string = \"s\"; kids: Vec<int32> = [1]; }\nclass Box<T> { item: T; constructor(item: T) { this.item = item; } }\nfunction take<T>(b: Box<T>): T { return move b.item; }\n";
	const refused = [
		{ name: "a field of a generic instance holding a class", body: "export function run(): int32 { return take(new Box<Leaf>(new Leaf())).v; }", refusal: "cannot move 'b.item': type 'Leaf' has no default value" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains(item.refusal) && result.error.contains("swap(a, b)"), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
	const kept = [
		{ name: "a nullable field", body: "export function run(): int32 { const h = new Holder(); const t = move h.maybe; return t == null ? 0 : t.v; }" },
		{ name: "a number field", body: "export function run(): int32 { const h = new Holder(); return move h.n; }" },
		{ name: "a string field", body: "export function run(): int32 { const h = new Holder(); const t = move h.s; return t.length; }" },
		{ name: "a Vec field", body: "export function run(): int32 { const h = new Holder(); const t = move h.kids; return t.length; }" },
		{ name: "an identifier", body: "export function run(): int32 { const l = new Leaf(); const t = move l; return t.v; }" },
		{ name: "a generic instance holding a number", body: "export function run(): int32 { return take(new Box<int32>(3)); }" },
		{ name: "a field of class type, its local holder dropped unread", body: "export function run(): int32 { const h = new Holder(); const t = move h.leaf; return t.v; }" },
		{ name: "an element of a class array, its local holder dropped unread", body: "export function run(): int32 { const xs: Leaf[] = [new Leaf()]; const t = move xs[0]; return t.v; }" },
		{ name: "a field of a struct type that holds a class, its local holder dropped unread", body: "export function run(): int32 { const h = new Holder(); const w = move h.wrap; return w.leaf.v; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
	const lib = "export class Box<T> { item: T; constructor(item: T) { this.item = item; } }\nexport function take<T>(b: Box<T>): T { return move b.item; }";
	const uses = [
		{ use: "class Leaf { v: int32 = 7; }\nconsole.log(take(new Box<Leaf>(new Leaf())).v);", refusals: 1 },
		{ use: "console.log(take(new Box<int32>(3)));", refusals: 0 },
	];
	for (const item of uses) {
		let hits = 0;
		for (const m of checkProjectDiagnostics([{ entryPath: "src/lib.ms", entrySource: lib }, { entryPath: "src/main.ms", entrySource: "import { Box, take } from \"./lib\";\n" + item.use }], "src/main.ms")) {
			if (m.indexOf("in instantiation of 'take") >= 0 && m.indexOf("cannot move 'b.item': type 'Leaf' has no default value") >= 0) hits += 1;
		}
		assert hits == item.refusals, item.use + ": " + String(hits) + " refusals";
	}
}

test "bindingOwnership: an explicit move out of a path a dead local owns by value is kept, and refused when the local is used again or the path crosses a reference" {
	const shapes = "class Leaf { v: int32 = 7; }\nstruct Wrap { leaf: Leaf; }\nstruct Outer { wrap: Wrap; n: int32; }\nclass Room { wrap: Wrap = { leaf: new Leaf() }; }\nstruct Shelf { room: Room; }\nfunction made(): Result<Leaf, string> { return Result.ok(new Leaf()); }\nlet g: Wrap = { leaf: new Leaf() };\n";
	const kept = [
		{ name: "a field", body: "export function run(): int32 { let w: Wrap = { leaf: new Leaf() }; const t = move w.leaf; return t.v; }" },
		{ name: "an element", body: "export function run(): int32 { let xs: Vec<Leaf> = [new Leaf()]; const t = move xs[0]; return t.v; }" },
		{ name: "a nested struct field", body: "export function run(): int32 { let o: Outer = { wrap: { leaf: new Leaf() }, n: 1 }; const t = move o.wrap.leaf; return t.v + 0; }" },
		{ name: "a Result payload", body: "export function run(): int32 { let r = made(); if (!r.ok) return 0; const t = move r.value; return t.v; }" },
		{ name: "a holder without a destroy hook", body: "struct Bare { leaf: Leaf; tag: number; }\nexport function run(): int32 { let b: Bare = { leaf: new Leaf(), tag: 1 }; return (move b.leaf).v; }" },
		{ name: "a local declared inside the loop", body: "export function run(): int32 { let s = 0; for (let i = 0; i < 2; i++) { let w: Wrap = { leaf: new Leaf() }; const t = move w.leaf; s += t.v; } return s; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
	const refused = [
		{ name: "the local is read after the move", body: "export function run(): int32 { let w: Wrap = { leaf: new Leaf() }; const t = move w.leaf; return t.v + w.leaf.v; }", refusal: "cannot use 'w.leaf.v': 'w.leaf' was moved out of it at 8:78 and is not put back yet" },
		{ name: "a loop runs the move again", body: "export function run(): int32 { let w: Wrap = { leaf: new Leaf() }; let s = 0; for (let i = 0; i < 2; i++) { const t = move w.leaf; s += t.v; } return s; }", refusal: "cannot use 'w.leaf': 'w.leaf' was moved out at 8:119 and is not put back yet" },
		{ name: "a local aliasing a path through a class reference", body: "export function run(): int32 { let s: Shelf = { room: new Room() }; const room = s.room; const t = move room.wrap.leaf; return t.v; }", refusal: "cannot move 'room.wrap.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
		{ name: "a class hop on the path", body: "export function run(): int32 { let s: Shelf = { room: new Room() }; const t = move s.room.wrap.leaf; return t.v; }", refusal: "cannot move 's.room.wrap.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
		{ name: "a ref parameter root", body: "function take(ref w: Wrap): Leaf { return move w.leaf; }\nexport function run(): int32 { let w: Wrap = { leaf: new Leaf() }; return take(w).v; }", refusal: "cannot move 'w.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
		{ name: "a this root", body: "function take(this w: Wrap): Leaf { return move w.leaf; }\nexport function run(): int32 { let w: Wrap = { leaf: new Leaf() }; return w.take().v; }", refusal: "cannot move 'w.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
		{ name: "a captured local", body: "export function run(): int32 { let w: Wrap = { leaf: new Leaf() }; const f = (): int32 => w.leaf.v; const t = move w.leaf; return t.v + f(); }", refusal: "cannot move 'w.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
		{ name: "a destroy hook of the holder reads the slot", body: "struct Kept { leaf: Leaf; tag: number; }\nfunction onDestroy(this k: Kept): void { console.log(String(k.leaf.v)); }\nexport function run(): int32 { let k: Kept = { leaf: new Leaf(), tag: 1 }; return (move k.leaf).v; }", refusal: "and Kept's onDestroy reads it when 'k' is destroyed" },
		{ name: "a destroy hook of the root reads a nested slot", body: "struct Inner { leaf: Leaf; }\nstruct Shell { i: Inner; tag: number; }\nfunction onDestroy(this s: Shell): void { console.log(String(s.i.leaf.v)); }\nexport function run(): int32 { let s: Shell = { i: { leaf: new Leaf() }, tag: 1 }; return (move s.i.leaf).v; }", refusal: "and Shell's onDestroy reads it when 's' is destroyed" },
		{ name: "a destroy hook reached through an alias", body: "struct Kept { leaf: Leaf; tag: number; }\nfunction onDestroy(this k: Kept): void { console.log(String(k.leaf.v)); }\ntype Held = Kept;\nexport function run(): int32 { let k: Held = { leaf: new Leaf(), tag: 1 }; return (move k.leaf).v; }", refusal: "onDestroy reads it when 'k' is destroyed" },
		{ name: "a global root", body: "export function run(): int32 { const t = move g.leaf; return t.v; }", refusal: "cannot move 'g.leaf': type 'Leaf' has no default value, so the move would leave the field without a value —" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains(item.refusal), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
}

test "bindingOwnership: an explicit move of a variable a closure captures is refused, naming the variable" {
	const shapes = "class Box { n: string = \"\"; }\n";
	const refused = [
		{ name: "an arrow reads it", body: "export function run(): string { const x = new Box(); const f = () => x.n; const k = move x; return f() + k.n; }", variable: "x" },
		{ name: "a nested function reads it", body: "export function run(): string { const y = \"y\" + String(1); function g(): string { return y; } const z = move y; return g() + z; }", variable: "y" },
		{ name: "the closure itself moves it", body: "export function run(): string { const w = new Box(); const f = () => { const k = move w; return k.n; }; return f(); }", variable: "w" },
		{ name: "an arrow declared after the move reads it", body: "export function run(): string { const x = new Box(); const k = move x; const f = () => x.n; return f() + k.n; }", variable: "x" },
		{ name: "a nested function declared after the move reads it", body: "export function run(): string { const y = \"y\" + String(1); const z = move y; function g(): string { return y; } return g() + z; }", variable: "y" },
		{ name: "a parameter read by a function expression", body: "export function run(p: string): string { const f = function (): string { return p; }; const k = move p; return f() + k; }", variable: "p" },
	];
	for (const item of refused) {
		const result = compileToC(shapes + item.body);
		assert !result.ok && result.error.contains("cannot move '" + item.variable + "': a closure captures it"), item.name + (result.ok ? " compiled" : ": " + result.error);
	}
	const kept = [
		{ name: "no closure", body: "export function run(): string { const x = new Box(); const k = move x; return k.n; }" },
		{ name: "a closure over another variable", body: "export function run(): string { const x = new Box(); const o = new Box(); const f = () => o.n; const k = move x; return f() + k.n; }" },
		{ name: "a variable the closure declares", body: "export function run(): string { const f = () => { const x = new Box(); const k = move x; return k.n; }; return f(); }" },
		{ name: "a field of a captured variable", body: "export function run(): string { const x = new Box(); const f = () => x.n; const k = move x.n; return f() + k; }" },
	];
	for (const item of kept) {
		const result = compileToC(shapes + item.body);
		assert result.ok, item.name + (result.ok ? "" : ": " + result.error);
	}
}

test "bindingOwnership: a move of a captured variable in a generic body instantiated from another module is refused" {
	const libs = [
		{ name: "a generic function, closure before the move", lib: "export function f<T>(x: T): T { const read = (): T => x; const y = move x; read(); return y; }", use: "f(new Box());" },
		{ name: "a generic function, closure after the move", lib: "export function f<T>(x: T): T { const y = move x; const read = (): T => x; read(); return y; }", use: "f(new Box());" },
		{ name: "a generic method", lib: "export class H<T> { run(x: T): T { const read = (): T => x; const y = move x; read(); return y; } }", use: "new H<Box>().run(new Box());" },
	];
	for (const item of libs) {
		const main = "import { " + (item.use.startsWith("f(") ? "f" : "H") + " } from \"./lib\";\nclass Box { n: string = \"\"; }\n" + item.use;
		let hits = 0;
		for (const m of checkProjectDiagnostics([{ entryPath: "src/lib.ms", entrySource: item.lib }, { entryPath: "src/main.ms", entrySource: main }], "src/main.ms")) {
			if (m.indexOf("cannot move 'x': a closure captures it") >= 0) hits += 1;
		}
		assert hits == 1, item.name + ": " + String(hits) + " refusals";
	}
}

test "binding ownership: imports and implicit prelude visibility do not become exports" {
	const consumers = [
		{ module: "std/core/array", name: "push", source: "import { k, push } from \"./library\"; const a: number[] = []; push(a, k); a.push(k);" },
		{ module: "std/core/struct", name: "hashString", source: "import { k, hashString } from \"./library\"; console.log(hashString(\"a\").toString() + k.toString());" },
	];
	for (const consumer of consumers) {
		const policies = [
			{ prefix: "", exported: false },
			{ prefix: "import { " + consumer.name + " } from \"" + consumer.module + "\";", exported: false },
			{ prefix: "export { " + consumer.name + " } from \"" + consumer.module + "\";", exported: true },
			{ prefix: "export * from \"" + consumer.module + "\";", exported: true },
		];
		for (const policy of policies) {
			const entries: MapEntry[] = [
				{ entryPath: "src/library.ms", entrySource: policy.prefix + "\nexport const k = 7;" },
				{ entryPath: "src/main.ms", entrySource: consumer.source },
			];
			const diagnostics = checkProjectDiagnostics(entries, "src/main.ms");
			assert policy.exported ? diagnostics.length == 0 : diagnostics.length > 0, consumer.name + ": " + policy.prefix;
			if (policy.exported) {
				const c = compileProjectToCWithStd(entries, "src/main.ms");
				assert !c.startsWith("ERROR"), c;
			}
		}
	}
}

function defaultGraph(use: string, nullable: boolean): ModuleGraph {
	resetBuildState();
	const parameter = nullable ? "DefaultValue | null" : "DefaultValue";
	const library = "export class DefaultValue { n: int32 = 1; } export function f(o: " + parameter + " = null): int32 { return 1; } export class Option { n: int32; constructor(o: " + parameter + " = null) { this.n = 2; } }";
	const entries: MapEntry[] = [
		{ entryPath: "/src/defaultLibrary.ms", entrySource: library },
		{ entryPath: "/src/defaultEntry.ms", entrySource: use },
	];
	const graph = loadModuleGraph("/src/defaultEntry.ms", createMapProvider(entries));
	checkModuleGraph(graph, "");
	return graph;
}

function moduleErrors(graph: ModuleGraph, path: string): int32 {
	const mod = findModule(graph, path);
	if (mod == null) return -1;
	let count: int32 = 0;
	for (const error of mod.errors) if (error.severity == ErrorSeverity.Error) count += 1;
	return count;
}

test "binding ownership: default diagnostics belong to their declaring module, once per declaration" {
	for (const use of [
		"import { f } from \"./defaultLibrary\"; const result: int32 = f();",
		"import { Option } from \"./defaultLibrary\"; const result: int32 = new Option().n;",
	]) {
		const graph = defaultGraph(use, false);
		assert moduleErrors(graph, "/src/defaultLibrary.ms") == 2, use;
		assert moduleErrors(graph, "/src/defaultEntry.ms") == 0, use;
		const ctx = lookupModuleCtx("/src/defaultLibrary.ms");
		assert ctx != null;
		let contextErrors: int32 = 0;
		for (const error of ctx.errors) if (error.severity == Severity.Error) contextErrors += 1;
		assert contextErrors == moduleErrors(graph, "/src/defaultLibrary.ms"), use;
		const valid = defaultGraph(use, true);
		assert moduleErrors(valid, "/src/defaultLibrary.ms") == 0, use;
		assert moduleErrors(valid, "/src/defaultEntry.ms") == 0, use;
	}
}

test "binding ownership: imported static extensions belong to their receivers, not a bare overload set" {
	const library = "export struct Pet { hunger: uint16; } export struct Block { id: uint32; } export function create(x: int32): int32 { return x + 1; } export function create(this typeof Pet): Pet { return { hunger: 7 }; } export function create(this typeof Block): Block { return { id: 9 }; } export function make(this typeof Pet): Pet { return { hunger: 3 }; }";
	const cases = [
		{ source: "import { Pet, Block, create } from \"./library\"; const b: uint32 = Block.create().id; const p: uint16 = Pet.create().hunger; const n: int32 = create(4);", accepted: true },
		{ source: "import * as lib from \"./library\"; const b: uint32 = lib.Block.create().id; const p: uint16 = lib.Pet.create().hunger;", accepted: true },
		{ source: "import { Pet, make } from \"./library\"; const p: Pet = make();", accepted: false },
		{ source: "import { Pet, make } from \"./library\"; const p: uint16 = Pet.make().hunger;", accepted: true },
	];
	for (const item of cases) {
		const entries: MapEntry[] = [
			{ entryPath: "src/library.ms", entrySource: library },
			{ entryPath: "src/main.ms", entrySource: item.source },
		];
		const diagnostics = checkProjectDiagnostics(entries, "src/main.ms");
		assert item.accepted ? diagnostics.length == 0 : diagnostics.length > 0, item.source;
	}
}
