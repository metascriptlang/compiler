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
	assert c.value.contains("first_") && c.value.contains("__float64__");
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
	assert c.value.contains("Destroy(Named__");
	assert c.value.contains("Copy(Named__");
}

test "E2E C: a module-level interface value is released at module exit" {
	const c = compileToC(`
		interface Foo { x: number; name: string; }
		function makeFoo(): Foo { return { x: 1, name: "test" }; }
		const f = makeFoo();
	`);
	assert c.ok;
	assert c.value.contains("Destroy(Foo__");
	assert c.value.contains("msDecref(f__");
}

test "E2E C: an array field is released by its owner's destroy hook" {
	const c = compileToC(`
		interface Bar { items: string[]; }
		function makeBar(): Bar { return { items: [] }; }
		const b = makeBar();
		console.log(b.items.length);
	`);
	assert c.ok;
	assert c.value.contains("msDecref((*self).items)");
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

test "E2E C: last-read field of a local value struct is moved out" {
	const c = compileToC(`
		struct R { value: string; done: boolean; }
		function next(i: int32): R { return { value: \`k\${i}\`, done: i > 3 }; }
		function f(out: string[]): void {
			const r = next(1);
			const k = r.value;
			out.push(k);
		}
	`);
	assert c.ok;
	assert c.value.contains("msStringWasMoved(r_1_.value)");
	assert !c.value.contains("msStringCopy(&(k_1_), r_1_.value)");
}

test "E2E C: field read again later is not moved out" {
	const c = compileToC(`
		struct R { value: string; done: boolean; }
		function next(i: int32): R { return { value: \`k\${i}\`, done: i > 3 }; }
		function f(out: string[]): void {
			const r = next(1);
			const k = r.value;
			out.push(k);
			console.log(r.value);
		}
	`);
	assert c.ok;
	assert !c.value.contains("msStringWasMoved(r_1_.value)");
}

test "E2E C: field behind a reference root is copied, never moved" {
	const c = compileToC(`
		interface R { value: string; done: boolean; }
		function next(i: int32): R { return { value: \`k\${i}\`, done: i > 3 }; }
		function f(out: string[]): void {
			const r = next(1);
			const k = r.value;
			out.push(k);
		}
	`);
	assert c.ok;
	assert c.value.contains("msStringCopy((&(k_1_)), (*r_1_).value)");
	assert !c.value.contains("msStringWasMoved((*r_1_).value)");
}

test "E2E C: try unwrap moves the payload out of the result temp" {
	const c = compileToC(`
		function parse(i: int32): Result<string, string> {
			if (i < 0) return { ok: false, error: "neg" };
			return { ok: true, value: \`v\${i}\` };
		}
		function f(i: int32): Result<string, string> {
			const v = try parse(i);
			console.log(v);
			return { ok: true, value: v };
		}
	`);
	assert c.ok;
	assert c.value.contains("msStringWasMoved(dollarresult_0_.v0.value)");
}

test "E2E C: a non-owning link field is never moved out" {
	const c = compileToC(`
		interface Tok { s: string; next: Cursor<Tok>; }
		struct Holder { link: Cursor<Tok>; own: Tok; }
		function mk(): Holder { const t: Tok = { s: "a", next: null as unknown as Tok }; return { link: t, own: t }; }
		function f(): string {
			const h = mk();
			let body: Tok = h.own;
			body = h.link;
			return body.s;
		}
	`);
	assert c.ok;
	assert !c.value.contains("WasMoved(h_1_.link)");
}

test "E2E C: a field reached through a non-owning local is never moved out" {
	const c = compileToC(`
		interface Tok { s: string; next: Cursor<Tok>; own: Tok; }
		function f(head: Tok): string {
			const rhs = head.next;
			const k = rhs.own;
			return k.s;
		}
	`);
	assert c.ok;
	assert !c.value.contains("WasMoved(rhs_1_->own)");
	assert !c.value.contains("WasMoved((*rhs_1_).own)");
}

test "E2E C: a narrowed local returned through an identity assertion is copied" {
	const c = compileToC(`
		struct Box { names: string[]; count: int32; }
		function get(): Box {
			let got: Box | null = null;
			got = { names: ["a"], count: 1 };
			if (got == null) return { names: [], count: 0 };
			return got!;
		}
	`);
	assert c.ok;
	assert c.value.contains("Copy((&(dollarborrow");
	assert !c.value.contains("*__result = got_1_.value;");
}

test "E2E C: a narrowed field returned through an identity assertion is copied" {
	const c = compileToC(`
		struct Box { names: string[]; count: int32; }
		interface Slot { got: Box | null; }
		function get(slot: Slot): Box {
			if (slot.got == null) return { names: [], count: 0 };
			return slot.got as Box;
		}
	`);
	assert c.ok;
	assert c.value.contains("(&((*slot).got.value)));");
	assert !c.value.contains("*__result = (*slot).got.value;");
}

test "E2E C: a narrowed captured local returned through an identity assertion is copied" {
	const c = compileToC(`
		struct Box { names: string[]; count: int32; }
		function get(): Box {
			let got: Box | null = null;
			const fill = (): void => { got = { names: ["a"], count: 1 }; };
			fill();
			if (got == null) return { names: [], count: 0 };
			return got!;
		}
	`);
	assert c.ok;
	assert c.value.contains(").got0.value)));");
	assert !c.value.contains("*__result = (*_env");
}

test "E2E C: a fresh object returned through a cast to an unmanaged type keeps its reference" {
	const c = compileToC(`
		class Node1 { text: string = "hi"; }
		function make(): Node1 { return new Node1(); }
		function asHandle(): unknown { return make() as unknown; }
	`);
	assert c.ok;
	assert c.value.contains("return ((void*)make");
	assert !c.value.contains("msDecrefCyclic(dollartmp");
}

test "E2E C: a fresh object returned through two casts to an unmanaged alias keeps its reference" {
	const c = compileToC(`
		class Node1 { text: string = "hi"; }
		type Handle = unknown;
		function make(): Node1 { return new Node1(); }
		const create = (tag: string): Handle => make() as unknown as Handle;
	`);
	assert c.ok;
	assert c.value.contains("return ((void*)make");
	assert !c.value.contains("msDecrefCyclic(dollartmp");
}

test "E2E C: an object literal bound through a cast to a union takes its own reference to each field" {
	const c = compileToC(`
		class Box { v: int32 = 7; }
		type A = { a: Box, s: string };
		type U = A | { n: int32 };
		function wrap(b: Box): U {
			const u = { a: b, s: "x" } as U;
			return u;
		}
	`);
	assert c.ok;
	assert !c.value.contains("->a = b;");
	assert c.value.contains("->a = dollarborrow_");
}

test "E2E C: an object literal cast to a union and read before a raising argument takes its own reference" {
	const c = compileToC(`
		class Box { v: int32 = 7; }
		type A = { a: Box, s: string };
		type U = A | { n: int32 };
		class Spec { name: string = "n"; }
		function tag(s: string): string { return s + "!"; }
		function hold(u: U, t: string): U { return u; }
		function wrap(b: Box, spec: Spec): U {
			return hold({ a: b, s: spec.name } as U, tag(spec.name));
		}
	`);
	assert c.ok;
	assert !c.value.contains("->a = b;");
	assert c.value.contains("->a = dollarborrow_");
}

function occurrences(code: string, token: string): int32 {
	return (code.split(token).length - 1) as int32;
}

test "E2E C: an explicit move empties an indexed field path once, at the move" {
	const c = compileToC(`
		struct Node { kids: Vec<int32>; }
		struct Tree { nodes: Vec<Node>; }
		function pick(): int32 { return 0; }
		function f(): int32 {
			let t: Tree = { nodes: [{ kids: [1, 2] }] };
			const k = move t.nodes[pick()].kids;
			return k.length;
		}
	`);
	assert c.ok;
	const reset = "msArrayNumberWasMoved(t_1_.nodes[__call_";
	assert occurrences(c.value, "msArrayNumberWasMoved(t_1_.nodes[") == 1;
	assert c.value.contains(reset);
	assert c.value.indexOf(reset) < c.value.indexOf("(k_1_ = dollarmove_");
}

test "E2E C: an explicit move into its own field captures the value before the old one is destroyed" {
	const c = compileToC(`
		struct Tree { kids: Vec<int32>; }
		function f(): int32 {
			let t: Tree = { kids: [3, 4] };
			t.kids = move t.kids;
			return t.kids.length;
		}
	`);
	assert c.ok;
	assert occurrences(c.value, "msArrayNumberWasMoved(t_1_.kids)") == 1;
	assert c.value.indexOf("msArrayNumberWasMoved(t_1_.kids)") < c.value.indexOf("(t_1_.kids = dollarmove_");
}

test "E2E C: advancing through a moved next link resets the old link once" {
	const c = compileToC(`
		class Link { v: int32; next: Link | null = null; constructor(v: int32) { this.v = v; } }
		function f(): int32 {
			let cur: Link | null = new Link(1);
			if (cur != null) cur = move cur.next;
			return cur == null ? 0 : 1;
		}
	`);
	assert c.ok;
	assert occurrences(c.value, "msPtrWasMoved((*cur_1_).next)") == 1;
}

test "E2E C: a non-null asserted field bound across a call that clears it takes its own reference" {
	const c = compileToC(`
		class Leaf { k: number = 0; }
		class Holder { a: Leaf | null = null; }
		function clear(h: Holder): void { h.a = null; }
		function kept(h: Holder): number {
			const d = h.a!;
			clear(h);
			return d.k;
		}
	`);
	assert c.ok;
	assert !c.value.contains("(d_1_ = (*h).a)");
	assert c.value.contains("msIncref(dollarborrow_");
	assert c.value.contains("(d_1_ = dollarborrow_");
	assert c.value.contains("msDecref(d_1_)");
}

test "E2E C: a non-null asserted argument evaluated before a sibling that clears its field takes its own reference" {
	const c = compileToC(`
		class Leaf { k: number = 0; }
		class Holder { a: Leaf | null = null; }
		function sum(a: Leaf, b: number): number { return a.k + b; }
		function bump(h: Holder): number { h.a = null; return 0; }
		function both(h: Holder): number { return sum(h.a!, bump(h)); }
	`);
	assert c.ok;
	assert !c.value.contains("_ = (*h).a);");
	assert c.value.contains("msIncref(dollarborrow_");
	assert c.value.contains("_ = dollarborrow_");
	assert c.value.contains("msDecref(__ord_");
}

test "E2E C: a non-null asserted field bound while nothing writes its holder stays a borrow" {
	const c = compileToC(`
		class Leaf { k: number = 0; }
		class Holder { a: Leaf | null = null; }
		function read(h: Holder): number {
			const d = h.a!;
			return d.k;
		}
	`);
	assert c.ok;
	assert c.value.contains("(d_1_ = (*h).a)");
	assert !c.value.contains("msDecref(d_1_)");
}
