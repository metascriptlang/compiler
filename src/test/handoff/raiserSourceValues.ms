import { evalSourceFull } from "../../codegen/raiser/eval";
import { InlineFrame, Type, SymbolKind, TypeKind, makeLoc } from "../../ast/node";
import { createPrimitive, createStruct, createMaybeType } from "../../checker/types";
import { makeSymbol } from "../../checker/symbol";
import { makeIdentResolved } from "../../transform/util";
import { RaiserCompState, createCompState, allocPackedBlock, declareLocal } from "../../codegen/raiser/context";
import { packedSlotShapeOf } from "../../codegen/raiser/valueCopy";
import { compilePackedExpr } from "../../codegen/raiser/expressions";

test "packed source: nested POD copies do not alias and use native field offsets" {
	const ctx = evalSourceFull(`
		struct Inner { a: uint8; b: int32; }
		struct Outer { left: uint8; inner: Inner; right: int64; }
		@noinline function copy(p: Outer): Outer { return p; }
		function run(): int64 {
			const a: Outer = { left: 3, inner: { a: 4, b: 5 }, right: 6 };
			let b = copy(a);
			b.inner.b = 9;
			b.inner.a += 1;
			return a.inner.b * 100 + b.inner.b * 10 + b.inner.a;
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 595;
}

test "packed source: return snapshots all words before finally mutates the local" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function get(): Pair {
			let p: Pair = { x: 2, y: 3 };
			try { return p; } finally { p.x = 7; p.y = 8; }
		}
		const p = get(); return p.x * 10 + p.y;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 23;
}

test "packed source: a path argument is read at the call, after later arguments mutate it, as on C and JS" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function first(p: Pair, n: int64): int64 { return p.x * 10 + p.y + n; }
		@noinline function mutate(ref p: Pair): int64 { p.x = 7; return 7; }
		function run(): int64 {
			let p: Pair = { x: 2, y: 3 };
			return first(p, mutate(p));
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 80;
}

test "packed source: nullable presence and nullish coalescing keep zero and false" {
	const ctx = evalSourceFull(`
		@noinline function zero(): int64 | null { return 0; }
		@noinline function no(): boolean | null { return false; }
		const z = zero(); const b = no();
		return (z != null ? 10 : 0) + (z ?? 9) + (b != null ? 20 : 0) + ((b ?? true) ? 1 : 0);
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 30;
}

test "packed source: nullable truthiness distinguishes absence negative zero and NaN" {
	const ctx = evalSourceFull(`
		@noinline function value(n: int32): float64 | null {
			if (n == 0) return null;
			if (n == 1) return -0.0;
			if (n == 2) return NaN;
			return 2.5;
		}
		let out: int64 = 0;
		for (let i: int32 = 0; i < 4; i++) {
			const p = value(i);
			if (p != null) out += 10;
			if (p) out += 1;
		}
		return out;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 31;
}

test "packed source: an impure nullable condition runs once" {
	const ctx = evalSourceFull(`
		let calls: int64 = 0;
		@noinline function next(): int64 | null { calls++; return 0; }
		const v = next() ?? 9;
		return calls * 10 + v;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 10;
}

test "packed source: checked absent projections still fail" {
	const ctx = evalSourceFull(`
		@noinline function absent(): int64 | null { return null; }
		function run(): int64 {
			const p = absent(); return p as int64;
		}
		return run();
	`);
	assert ctx.hasModule, ctx.lastError;
	assert ctx.lastError != "";
}

test "packed source: a closure calls a legacy entry and returns every word" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function make(n: int64): Pair { return { x: n, y: n + 1 }; }
		const f = make;
		const p = f(4); return p.x * 10 + p.y;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 45;
}

test "packed source: author ref writes the original struct and its member" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function change(ref p: Pair): void { p.x = 8; }
		@noinline function inc(ref n: int64): void { n++; }
		function run(): int64 {
			let p: Pair = { x: 2, y: 3 };
			change(p); inc(p.y); return p.x * 10 + p.y;
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 84;
}

test "packed source: legacy containers keep their own cells beside frame copies" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		function run(): int64 {
			let p: Pair = { x: 2, y: 3 };
			const xs: Pair[] = [p]; p.x = 8;
			let q = xs[0]; q.y = 9;
			return xs[0].x * 100 + xs[0].y * 10 + q.y;
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 239;
}

test "packed source: an inferred borrowed result materializes before root mutation" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function first(p: Pair): Borrow<int64> { return p.x; }
		@noinline function change(ref p: Pair): void { p.x = 8; }
		let p: Pair = { x: 2, y: 3 };
		const view = first(p); change(p); return view;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 2;
}

test "packed source: a mixed block and closure argument survive the call window" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function apply(p: Pair, f: (x: int64) => int64): int64 { return f(p.x) + p.y; }
		function run(): int64 {
			const offset: int64 = 10;
			return apply({ x: 2, y: 3 }, (x: int64): int64 => x + offset);
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 15;
}

test "packed source: nullable assertion converts to the written numeric target" {
	const ctx = evalSourceFull(`
		@noinline function value(): float64 | null { return 17.75; }
		return value() as int32;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 17;
}

test "packed source: nullable assertion keeps the literal target check" {
	const ctx = evalSourceFull(`
		@noinline function value(): int64 | null { return 8; }
		return value() as 7;
	`);
	assert ctx.hasModule, ctx.lastError;
	assert ctx.lastError != "";
}

test "packed source: managed user hooks keep their old lifecycle beside raw POD" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		struct Resource { id: int64; text: string; }
		let drops: int64 = 0;
		function onDestroy(this r: Resource): void { drops += r.id; }
		@noinline function run(): int64 {
			const p: Pair = { x: 2, y: 3 };
			{ const r: Resource = { id: 7, text: "owned" }; }
			return p.x + p.y;
		}
		const n = run(); return drops * 10 + n;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 75;
}

test "packed source: a producer call crosses a legacy container boundary explicitly" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function make(n: int64): Pair { return { x: n, y: n + 1 }; }
		const xs: Pair[] = [make(4)];
		return xs[0].x * 10 + xs[0].y;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 45;
}

test "packed source: a producer call crosses a legacy class argument boundary explicitly" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		class Holder { value: Pair; constructor(p: Pair) { this.value = p; } }
		@noinline function make(n: int64): Pair { return { x: n, y: n + 1 }; }
		const h = new Holder(make(6)); return h.value.x * 10 + h.value.y;
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 67;
}

test "packed source: assigning a nested block preserves neighboring native bytes" {
	const ctx = evalSourceFull(`
		struct Inner { a: uint8; b: int32; }
		struct Outer { left: uint8; inner: Inner; right: int64; }
		function run(): int64 {
			let p: Outer = { left: 3, inner: { a: 4, b: 5 }, right: 6 };
			const saved = p.inner;
			p.inner = { a: 8, b: 9 };
			return p.left * 10000 + saved.b * 1000 + p.inner.b * 100 + p.inner.a * 10 + p.right;
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 35986;
}

test "packed source: fixed-array calls and constant element copies keep value semantics" {
	const ctx = evalSourceFull(`
		@noinline function make(): int64[2] { return [3, 4]; }
		function run(): int64 {
			const a = make(); let b = a; b[0] = 9;
			return a[0] * 100 + b[0] * 10 + b.length;
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 392;
}

function compileInlineSnapshot(type: Type): RaiserCompState {
	const s = createCompState();
	const sym = makeSymbol("p", SymbolKind.Variable, type, false);
	const shape = packedSlotShapeOf(s.layouts, type)!;
	declareLocal(s, sym, allocPackedBlock(s, shape), false, shape);
	const node = makeIdentResolved(sym, makeLoc(12, 2));
	node.inlineFrame = new InlineFrame("packedOrigin",
		new InlineFrame("outer", null, 7), 9);
	compilePackedExpr(s, node, type);
	return s;
}

test "packed source: a two-word snapshot retains its inline frame and restores the site" {
	const word = createPrimitive(TypeKind.Int64);
	const type = createStruct("Pair", ["x", "y"], [word, word], true);
	type.sym = makeSymbol("Pair", SymbolKind.Struct, type, false);
	let s: RaiserCompState | null = null;
	let diagnostic = "";
	try { s = compileInlineSnapshot(type); }
	catch (error) { diagnostic = error.message; }
	assert diagnostic == "", diagnostic;
	assert s != null;
	assert s!.code.length > 0;
	const site = s!.code[s!.code.length - 1].site;
	assert site > 0, "two-word snapshot lost its originating inline frame";
	assert s!.inlineSites[site - 1].name == "packedOrigin";
	assert s!.inlineSites[s!.inlineSites[site - 1].parent - 1].name == "outer";
	assert s!.site == 0;
}

test "packed source: a one-word Maybe snapshot retains its inline frame and restores the site" {
	let s: RaiserCompState | null = null;
	let diagnostic = "";
	try {
		s = compileInlineSnapshot(createMaybeType(
			createPrimitive(TypeKind.Boolean)));
	} catch (error) { diagnostic = error.message; }
	assert diagnostic == "", diagnostic;
	assert s != null;
	assert s!.code.length > 0;
	const site = s!.code[s!.code.length - 1].site;
	assert site > 0, "one-word Maybe snapshot lost its originating inline frame";
	assert s!.inlineSites[site - 1].name == "packedOrigin";
	assert s!.inlineSites[s!.inlineSites[site - 1].parent - 1].name == "outer";
	assert s!.site == 0;
}

test "packed source: a void middle argument runs after the first packed argument" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		let counter: int64 = 0;
		@noinline function first(): Pair { const before = counter; counter += 1; return { x: before, y: 0 }; }
		@noinline function bump(): void { counter += 10; }
		@noinline function take(p: Pair, effect: void, n: int64): int64 { return p.x * 100 + n; }
		return take(first(), bump(), counter);
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 11;
}

test "packed source: a void last argument does not run before earlier value arguments" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		let counter: int64 = 0;
		@noinline function first(): Pair { const before = counter; counter += 1; return { x: before, y: 0 }; }
		@noinline function bump(): void { counter += 10; }
		@noinline function take(p: Pair, n: int64, effect: void): int64 { return p.x * 100 + n; }
		return take(first(), counter, bump());
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 1, `actual ${ctx.lastResult.intVal}`;
}


test "packed source: a checked absent aggregate binding still fails" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function absent(): Pair | null { return null; }
		function run(): int64 {
			const p = absent() as Pair;
			return p.x + p.y;
		}
		return run();
	`);
	assert ctx.hasModule, ctx.lastError;
	assert ctx.lastError.split("\n")[0] == "member 'Pair' is not accessible for type 'Pair | null' using 'null'", ctx.lastError;
}

test "packed source: erased arguments keep closure holds below the physical window" {
	const ctx = evalSourceFull(`
		struct Pair { x: int64; y: int64; }
		@noinline function nothing(): void {}
		@noinline function apply(p: Pair, effect: void,
			f: (x: int64) => int64, tail: void): int64 {
			return f(p.x) + p.y;
		}
		function run(): int64 {
			const offset: int64 = 10;
			return apply({ x: 2, y: 3 }, nothing(),
				(x: int64): int64 => x + offset, nothing());
		}
		return run();
	`);
	assert ctx.lastError == "", ctx.lastError;
	assert ctx.lastResult.intVal == 15;
}
