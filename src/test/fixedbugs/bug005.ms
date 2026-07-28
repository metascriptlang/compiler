// bug005 — class method/ctor param signature missed ccgIntroducedPtr promotion
//
// Symptom:    Calling a class method (or constructor) with an array
//             (or any ccgIntroducedPtr type — Array/Union/Span/big struct)
//             as a *named* argument produced a C compile error:
//                 "passing 'msStringArray *' to parameter of incompatible
//                  type 'msStringArray'; remove &"
//             Standalone-to-standalone calls with the same array param
//             worked. Hit by ion command-builder while threading args
//             arrays through CLI handler methods.
//
// Root cause: Codegen had a parallel `genMethodAsFunction` (and
//             `genConstructor`) path that skipped the
//             `shouldIndirectParam` promotion `genFunctionDecl` applies,
//             so method/ctor signatures emitted `msStringArray` (by-value)
//             while standalone fn emitted `msStringArray*`. Caller-side
//             `shimCallArg` adds `&` unconditionally for ccgIntroducedPtr
//             — the asymmetry put the caller and method signatures out of
//             sync.
//
// Fix:        New transform `methodToFunction` (Phase 3, !jsBackend
//             branch) lifts every MethodDecl + ConstructorDecl out of the
//             class body into a top-level FunctionDecl. Codegen sees only
//             FunctionDecl and routes everything through `genFunctionDecl`
//             — single shared param-promotion path. NewExpr handler
//             inlines `alloc + <Class>_init(this, args)` at the call site,
//             matching the inline pattern already used for class-without-
//             ctor (and Nim's `genObjConstr`).

class Bug005Box {
	count(items: string[]): int32 {
		return items.length as int32;
	}
}

test "bug005: method with string[] param accepts named lvalue" {
	const b = new Bug005Box();
	const items: string[] = ["a", "b", "c"];
	const n = b.count(items);
	assert n === 3;
}

class Forward {
	// Method that forwards the array to a standalone function — original
	// shape from the ion command-builder report.
	process(items: string[]): int32 {
		return takeArr(items);
	}
}

function takeArr(arr: string[]): int32 {
	return arr.length as int32;
}

test "bug005: method body forwards array to standalone fn" {
	const f = new Forward();
	const items: string[] = ["x", "y"];
	const n = f.process(items);
	assert n === 2;
}

class Reader {
	// Method body reads .length on the array param — verifies indirectParams
	// auto-deref is wired so promoted params behave like value-typed params
	// inside the body.
	first(items: string[]): string {
		if (items.length === 0) return "";
		return items[0];
	}
}

test "bug005: method body indexes promoted array param" {
	const r = new Reader();
	const items: string[] = ["one", "two"];
	const got = r.first(items);
	assert got === "one";
}

class NumOp {
	// number[] is also ccgIntroducedPtr (Array kind) — same promotion path.
	sum(values: number[]): number {
		let total = 0;
		for (const v of values) {
			total = total + v;
		}
		return total;
	}
}

test "bug005: method with number[] param sums correctly" {
	const op = new NumOp();
	const values: number[] = [1, 2, 3, 4];
	const total = op.sum(values);
	assert total === 10;
}

class CtorBox {
	count: int32;
	constructor(items: int32[]) {
		this.count = items.length as int32;
	}
}

test "bug005: ctor with array param accepts array literal" {
	const c = new CtorBox([1, 2, 3]);
	assert c.count === 3;
}

// ===== Inheritance with ctor chain (super) =====
// Multi-level chain `A -> B -> C` exercises both the lifted `_init`
// FunctionDecl path AND the reachability extension that marks every
// parent's `_init` alive when a child's ctor calls super().

class A1 {
	x: int32;
	constructor(x: int32) { this.x = x; }
}

class B1 extends A1 {
	y: int32;
	constructor(x: int32, y: int32) {
		super(x);
		this.y = y;
	}
}

class C1 extends B1 {
	z: int32;
	constructor(x: int32, y: int32, z: int32) {
		super(x, y);
		this.z = z;
	}
}

test "bug005: 3-level inheritance with super() chain" {
	const c = new C1(10, 20, 30);
	assert c.x === 10;
	assert c.y === 20;
	assert c.z === 30;
}

// ===== Generic class ctor (paired fix in instantiate.ms) =====
// Generic classes monomorphize per concrete T. The mono path synthesises a
// `<MangledClass>` ClassDecl carrying only the constructor; the
// methodToFunction transform then lifts that ctor like any other into
// `<MangledClass>_init`. Without `classNode.nodeType` set on the synthetic
// node, the lift's receiver-type lookup falls back to `Unknown` →
// `this: void*` in the `_init` signature → `(*this).field` fails at the
// C compile step with `"no member named 'field' in struct <MangledClass>"`.
//
// We don't have an inline test here — the assertion path was unstable on
// the retired JS test harness. The fix is
// covered end-to-end by `examples/`-style probes (see probe2-generic
// in /tmp/ms-bugs/) and indirectly by std/core/struct.ms's HashMap/HashSet
// generics that flow through the same path and are exercised by the rest
// of the test suite.

// ===== Static method — separate code path from instance methods =====
// Static methods don't get a `this` prepend in `collectClassMethod`. The
// methodToFunction lift must still produce a top-level FunctionDecl with the
// correct (no-this) param shape — and the `Class.method(...)` call site must
// resolve to the lifted name.

class StaticOps {
	static sumAll(items: int32[]): int32 {
		let total: int32 = 0;
		for (const v of items) {
			total = total + (v as int32);
		}
		return total;
	}
}

test "bug005: static method with array param" {
	const items: int32[] = [1, 2, 3, 4];
	const total = StaticOps.sumAll(items);
	assert total === 10;
}

// ===== Cross-module class + inheritance =====
// Class defined in a sibling module; `new` site here. Exercises the
// reachability extension's cross-module markAndWalk path (mark `<class>_init`
// alive in the *defining* module, not the caller's).

import { CrossA, CrossB } from "./bug005helper";

test "bug005: cross-module class instantiation + method call" {
	const a = new CrossA(7);
	assert a.getX() === 7;
}

test "bug005: cross-module inheritance with super() across modules" {
	const b = new CrossB(3, 4);
	assert b.sum() === 7;
}
