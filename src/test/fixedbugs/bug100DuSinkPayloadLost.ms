// bug100 — a DU `=sink` copied the discriminant but not the payload
//
// Symptom:    re-assigning a union local kept the OLD branch's bytes — the
//             read came back stale or empty, and under churn the stale
//             pointer was destroyed twice (ASan heap-use-after-free in
//             <Union>_v0Destroy). Silent on C, correct on JS, and all three
//             C lanes agreed, so only a C↔JS comparison could see it.
// Root cause: buildVariantChain (the sinkAssign path in destructorLifting)
//             read `objType.typeChildren[vi].typeNames` without peeling
//             Ref/Ptr. Interface variants ARE Ref<Struct>, so typeNames was
//             null, every arm was skipped, and the assign chain collapsed to
//             nothing: the sink emitted destroy + tag copy and stopped.
//             Reference: liftdestructors.nim fillBodyObjT nkRecCase — for
//             attachedSink it destroys the old branch, assigns the selector,
//             then runs defaultOp (a plain field assign) inside each branch.
// Fix:        peelToStruct in buildVariantChain, matching the peel its sibling
//             buildVariantDispatch (destroy/copy/wasMoved/trace) already did.
//
// Shape notes, both load-bearing — an earlier draft of this guard passed
// against the broken compiler for want of them:
//   - the helper must return the UNION (a variant-returning helper takes the
//     widening path of bug099 and never reaches the hook), and
//   - the sequence must live in a plain function, not directly in a `test`
//     block: there the assignment stays a whole-struct blit, which copies the
//     payload by accident and hides the bug.

interface B100A { kind: "a"; label: string; n: int32; }
interface B100B { kind: "b"; label: string; f: float64; }
type B100U = B100A | B100B;

function b100u(which: boolean, n: int32): B100U {
	if (which) {
		const a: B100A = { kind: "a", label: "L" + n.toString(), n: n };
		return a;
	}
	const b: B100B = { kind: "b", label: "M" + n.toString(), f: 1.5 };
	return b;
}

function b100read(u: B100U): string {
	return u.label;
}

function b100Cross(): string {
	let u: B100U = b100u(true, 1);
	const first = b100read(u);
	u = b100u(false, 2);
	return first + "|" + u.kind + "|" + b100read(u);
}

function b100Same(): string {
	let u: B100U = b100u(true, 1);
	const first = b100read(u);
	u = b100u(true, 8);
	return first + "|" + u.kind + "|" + b100read(u);
}

function b100Churn(): int32 {
	let u: B100U = b100u(true, 0);
	let ok = 0;
	for (let i = 1; i <= 40; i += 1) {
		const before = b100read(u);
		u = b100u(i % 2 === 0, i);
		const want = i % 2 === 0 ? "L" + i.toString() : "M" + i.toString();
		if (b100read(u) === want && before !== "") {
			ok += 1;
		}
	}
	return ok;
}

test "bug100: sink carries the payload across variants" {
	assert b100Cross() === "L1|b|M2";
}

test "bug100: sink replaces same-variant fields" {
	assert b100Same() === "L1|a|L8";
}

test "bug100: repeated sink assignment stays consistent" {
	assert b100Churn() === 40;
}
