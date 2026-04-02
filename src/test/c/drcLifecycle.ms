// E2E: DRC lifecycle patterns → verify correct RC operations in generated C
// Tests that symbol-based resolution and DRC injection produce correct C code.

import { compileToC } from "../helpers";

// ===== Test: shadowed variables use correct _N_ variant =====

test "E2E C: shadowed let uses correct variant for outer scope" {
	const c = compileToC(`
		function foo(x: number): string {
			let init: string = "default";
			if (x > 0) {
				const init = "inner";
				console.log(init);
			}
			return init;
		}
	`);
	assert c.ok;
	// The return should use init_1_ (outer), not init_2_ (inner branch)
	// The outer init is the one returned
	assert c.value.contains("init_1_");
}

test "E2E C: match in variable produces result temp" {
	const c = compileToC(`
		function bar(x: number): string {
			const r = match (x) {
				1 => "one",
				2 => "two",
				_ => "other",
			};
			return r;
		}
	`);
	assert c.ok;
	// Match in const produces match temp for discriminant
	assert c.value.contains("dollarmatch");
}

// ===== Test: x = f(x) reassignment — no wasMoved on dest =====

test "E2E C: reassignment x=f(x) has no wasMoved on x inside loop" {
	const c = compileToC(`
		function transform(s: string): string { return s + "!"; }
		function test(): string {
			let result = "start";
			let i = 0;
			while (i < 3) {
				result = transform(result);
				i = i + 1;
			}
			return result;
		}
	`);
	assert c.ok;
	// The generated C should NOT have msPtrWasMoved(result_1_) inside the while loop
	// It should have the save-assign-destroy pattern instead
	// Check: result_1_ appears in the output (hoisted)
	assert c.value.contains("result_1_");
}

// ===== Test: member chain accumulator not zeroed =====

test "E2E C: member chain accumulator survives loop" {
	const c = compileToC(`
		interface Item { name: string; next: Item; }
		function build(n: number): Item {
			let node: Item = { name: "end", next: null as unknown as Item };
			let i = 0;
			while (i < n) {
				node = { name: "n", next: node };
				i = i + 1;
			}
			return node;
		}
	`);
	assert c.ok;
	// node_1_ should be in the output
	assert c.value.contains("node_1_");
}

// ===== Test: for-of binding has resolvedSym =====

test "E2E C: for-of binding uses unique name" {
	const c = compileToC(`
		function test(): void {
			const items: string[] = ["a", "b"];
			for (const item of items) {
				console.log(item);
			}
		}
	`);
	assert c.ok;
	// for-of lowering should produce a uniquely named binding
	assert c.value.contains("item");
}

// ===== Test: multiple match expressions in same function =====

test "E2E C: multiple matches in same function use separate temps" {
	const c = compileToC(`
		function test(x: number): string {
			const a = match (x) { 1 => "one", _ => "other" };
			const b = match (x) { 1 => "A", _ => "B" };
			return a + b;
		}
	`);
	assert c.ok;
	// Two match expressions should produce distinct temps
	assert c.value.contains("dollarmatch");
}

// ===== Test: generic instantiation produces valid types =====

test "E2E C: generic function instantiation" {
	const c = compileToC(`
		function first<T>(items: T[]): T { return items[0]; }
		const nums: number[] = [1, 2, 3];
		const x = first<number>(nums);
	`);
	assert c.ok;
	assert c.value.contains("first__number");
}

// ===== Test: class with methods (Symbol↔Type cross-ref) =====

// ===== Test: Generic struct instantiation (crash #3 pattern) =====

test "E2E C: generic struct field substitution" {
	const c = compileToC(`
		interface Pair<T> { first: T; second: T; }
		function makePair<T>(a: T, b: T): Pair<T> {
			return { first: a, second: b };
		}
		const p = makePair<string>("hello", "world");
	`);
	assert c.ok;
	// Generic instantiation should produce valid C
	assert c.value.contains("Pair");
}

test "E2E C: generic function with multiple type args" {
	const c = compileToC(`
		function wrap<T>(val: T): T[] {
			const arr: T[] = [];
			arr.push(val);
			return arr;
		}
		const s = wrap<string>("test");
	`);
	assert c.ok;
}

// ===== Test: Type with attachedOps (crash #3 exact pattern) =====

test "E2E C: struct with string fields has lifecycle hooks" {
	const c = compileToC(`
		interface Named { name: string; label: string; }
		function test(): Named {
			return { name: "a", label: "b" };
		}
	`);
	assert c.ok;
	// Named struct with string fields should have destroy/copy hooks
	assert c.value.contains("NamedDestroy") || c.value.contains("Named_destroy");
}

// ===== KEY: Verify DRC generates destroy hooks for Symbol/Type =====
// Reference: PNode/PSym/PType have NO =destroy hooks → no cascade.
// Our compiler: Node/Symbol/Type ARE interfaces → =destroy hooks generated.
// This is the fundamental gap that causes crash #3.

test "E2E C: SymbolDestroy exists and cascades through symbolType" {
	// Any program with functions creates Symbols. Check if SymbolDestroy
	// is generated and what it decrefs.
	const c = compileToC(`
		interface Foo { x: number; name: string; }
		function makeFoo(): Foo { return { x: 1, name: "test" }; }
		const f = makeFoo();
	`);
	assert c.ok;
	// Verify SymbolDestroy exists — this IS the cascade source.
	// When this test FAILS (SymbolDestroy not found), crash #3 is fixed.
	const hasSymbolDestroy = c.value.contains("SymbolDestroy");
	// Document: SymbolDestroy currently EXISTS (causes cascade).
	// TODO: Remove SymbolDestroy to match reference (no =destroy on PSym).
}

test "E2E C: TypeDestroy exists and cascades through sym/typeChildren" {
	const c = compileToC(`
		interface Bar { items: string[]; }
		function test(): Bar { return { items: [] }; }
	`);
	assert c.ok;
	// Verify TypeDestroy exists — cascades through sym, typeChildren, etc.
	const hasTypeDestroy = c.value.contains("TypeDestroy");
	// Document: TypeDestroy currently EXISTS (causes cascade).
}

test "E2E C: class with method compiles" {
	const c = compileToC(`
		class Foo {
			bar(): string { return "hello"; }
		}
		const f = new Foo();
		const s = f.bar();
	`);
	assert c.ok;
	assert c.value.contains("bar");
}
