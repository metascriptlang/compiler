// E2E: JS Backend

import { compileToJS, compileProjectToJSWithStd, MapEntry } from "../helpers";


test "E2E JS: const variable" {
	const js = compileToJS("const x = 42;");
	assert js.ok;
	assert js.value.contains("42");
}

test "E2E JS: function call" {
	const js = compileToJS("function add(a: number, b: number): number { return a + b; }\nconst r = add(1, 2);");
	assert js.ok;
	assert js.value.contains("function");
	assert js.value.contains("add");
}

test "E2E JS: enum" {
	const js = compileToJS("enum Dir { North, South }\nconst d: Dir = Dir.North;");
	assert js.ok;
	assert js.value.contains("Dir");
}

test "E2E JS: match expression" {
	const js = compileToJS("function f(x: number): number { return match (x) { 1 => 10, _ => 0, }; }\nconst r = f(1);");
	assert js.ok;
}

// KNOWN ISSUE: arrow functions fail in E2E pipeline (checker/transform rejects).
// test "E2E JS: arrow function" {
// 	const js = compileToJS("const double = (n: number): number => n * 2;\nconst r = double(5);");
// 	check(js.ok);
// }

test "E2E JS: interface object" {
	const js = compileToJS("interface Point { x: number; y: number }\nconst p: Point = { x: 1, y: 2 };");
	assert js.ok;
}

test "E2E JS: object literal completes omitted fields (C zero-fill parity)" {
	const js = compileToJS("interface Box { w: number | null; tag: string }\nconst b: Box = { tag: \"x\" };");
	assert js.ok;
	assert js.value.contains("w: null");
}

// gen-20 root 1+2 guard: a cross-module macro whose body calls a module-level
// helper must expand in the JS pipeline, and a failed expansion must be LOUD.
test "E2E JS: cross-module macro with module-level helper expands" {
	const macroMod = `import { Node, NodeKind } from "std/meta";

function shout(s: string): string {
	return s + "!";
}

export macro jsxmacx(node: Node): Node {
	return {
		kind: NodeKind.StringLiteral,
		line: node.line,
		column: node.column,
		value: shout("expanded-x"),
	};
}
`;
	const useMod = `import { jsxmacx } from "./jsxmacMod";
const x = jsxmacx(<div><p>hi</p></div>);
console.log(x);
`;
	const entries: MapEntry[] = [
		{ entryPath: "test/jsxmacMod.ms", entrySource: macroMod },
		{ entryPath: "test/jsxmacUse.ms", entrySource: useMod },
	];
	const js = compileProjectToJSWithStd(entries, "test/jsxmacUse.ms");
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("expanded-x");
	assert !js.contains("unsupported: MacroInvocation");
}

// The JS string surface drifted ~19 exports behind the C one and Neon's browser
// code hit it one name at a time. Every name below is declared in index.cms; a
// missing or misdeclared .jms counterpart fails the graph check, not codegen.
test "E2E JS: std string surface matches the C backend" {
	const src = `let s = "  Hello World  ";
const a: boolean = s.equalsIgnoreCase("x");
const b: int64 = s.count("l");
const c: string = s.substring(0, 3);
const d: string = s.trimStart();
const e: string = s.trimEnd();
const f: string = s.repeat(2);
const g: string = s.replaceAll("l", "L");
const h: string = s.reverse();
const i: string = s.padStart(20, ".");
const j: string = s.padEnd(20, ".");
const k: number = "3.5".parseFloat();
const l: int64 = "42".parseInt();
const m: int64 = s.capacity();
const n: string = fromCodePoint(65);
const o: int64 = s.lastIndexOf("l", 10);
s.setLength(4);
s.append("z");
s.setSlice(0, 2);
s.stripInPlace();
`;
	const entries: MapEntry[] = [
		{ entryPath: "test/strParity.ms", entrySource: src },
	];
	const js = compileProjectToJSWithStd(entries, "test/strParity.ms");
	assert js.indexOf("ERROR", 0) < 0;
}

// Nim jsgen parity (mangleName, jsgen.nim:228-281): module-level private decls
// carry module identity in their emitted JS name; the bundle is one flat scope
// and bare names are reserved for the exported/@emit ABI surface.
test "E2E JS: same-name private module decls get module-qualified names" {
	const modA = `function dupPrivHelper(): int32 { return 1; }
const dupPrivTag: int32 = 10;
export function fromDupA(): int32 { return dupPrivHelper() + dupPrivTag; }
`;
	const modB = `function dupPrivHelper(): int32 { return 2; }
const dupPrivTag: int32 = 20;
export function fromDupB(): int32 { return dupPrivHelper() + dupPrivTag; }
`;
	const useMod = `import { fromDupA } from "./dupPrivA";
import { fromDupB } from "./dupPrivB";
console.log(fromDupA().toString());
console.log(fromDupB().toString());
`;
	const entries: MapEntry[] = [
		{ entryPath: "test/dupPrivA.ms", entrySource: modA },
		{ entryPath: "test/dupPrivB.ms", entrySource: modB },
		{ entryPath: "test/dupPrivUse.ms", entrySource: useMod },
	];
	const js = compileProjectToJSWithStd(entries, "test/dupPrivUse.ms");
	assert js.indexOf("ERROR", 0) < 0;
	assert !js.contains("function dupPrivHelper(");
	assert js.count("function dupPrivHelper") === 2;
	assert !js.contains("const dupPrivTag =");
	assert js.count("dupPrivTag") >= 4;
	assert js.contains("function fromDupA(");
	assert js.contains("function fromDupB(");
	assert js.contains("fromDupA()");
	assert js.contains("fromDupB()");
}

// Nim jsgen parity (mangleName reservedWords, jsgen.nim:229-243): "this" is a JS
// reserved word — a lifted method's receiver binding must never emit bare. Class
// methods keep implicit bare `this`; monomorphised lifts bind `$this`.
test "E2E JS: generic class method lift renames the receiver binding" {
	const src = `class GenBox<T> {
	value: T;
	constructor(v: T) { this.value = v; }
	get(): T { return this.value; }
}
const gb = new GenBox<int32>(41);
console.log(gb.get().toString());
`;
	const entries: MapEntry[] = [
		{ entryPath: "test/genBox.ms", entrySource: src },
	];
	const js = compileProjectToJSWithStd(entries, "test/genBox.ms");
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("function GenBox_get");
	assert !js.contains("(this)");
	assert !js.contains("(this,");
	assert js.contains("return $this.value");
	assert js.contains("return this.value");
}

test "E2E JS: extends clause and super call keep their bindings" {
	const src = `class ExBase {
	w: number;
	constructor(w: number) { this.w = w; }
}
class ExKid extends ExBase {
	constructor(w: number) { super(w); }
}
const k = new ExKid(3);
console.log(k.w.toString());
`;
	const entries: MapEntry[] = [
		{ entryPath: "test/exKid.ms", entrySource: src },
	];
	const js = compileProjectToJSWithStd(entries, "test/exKid.ms");
	assert js.indexOf("ERROR", 0) < 0;
	assert js.contains("extends ExBase__");
	assert !js.contains("extends ExBase ");
	assert js.contains("super(");
	assert !js.contains("super__");
}
