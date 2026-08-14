// A LOCAL interface/struct declaration (inside a function body) must reach
// codegen through the module-statement lift. destructorLifting discovers types
// by walking programStmts and resolving names against the MODULE scope; a
// body-only decl got its hooks via the Ref-scan fallback but never a TypeInfo
// DEFINITION — undefined symbol _<T>TypeInfo at link, drc AND orc, invisible
// to compileToC-based tests (they stop before linking). The lifted node
// carries resolvedSym, and ensureHooksByName falls back to it when the
// module-scope name lookup misses. Local plain type aliases ride the same
// admission path but emit nothing. A local extern rides the same lift for a
// different reason: it defines no type, but its prototype is emitted from the
// module-level walk, so unlifted it links against nothing.
// GUARD-JS

function f(): number {
	interface P { x: number, s: string }
	const p: P = { x: 7, s: "hi" };
	return p.x + p.s.length;
}

function g(): number {
	struct Q { y: number, t: string }
	const q: Q = { y: 4, t: "abc" };
	return q.y + q.t.length;
}

function h(): number {
	type T = number;
	const v: T = 5;
	return v;
}

function k(): number {
	enum Level { Low = 2, High = 9 }
	const v: Level = Level.High;
	return v as number;
}

function m(): number {
	class Box {
		v: number = 0;
		tag: string = "";
		constructor(v: number) { this.v = v; this.tag = "b"; }
		double(): number { return this.v * 2; }
	}
	const b = new Box(21);
	return b.double() + b.tag.length;
}

function n(): number {
	when (c) {
		extern function myAbs(x: number): number from "abs";
		return myAbs(0 - 11);
	} else {
		return 11;
	}
}

const total = f() + g() + h() + k() + m() + n();
console.log(total);
if (total === 84) {
	console.log("GUARD-OK");
}
