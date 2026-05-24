// BUG #3 family — three TypeKinds that fall through unsafe default in
// classify.ms classifyArray(). Each is confirmed crash/corruption via
// /tmp/bug3-probe runtime probes.
//
// These tests EXPRESS the bug at the analyzer level: assert that the
// emitted destroy fn is wrong (current state) OR correct (post-fix).
//
// Pre-G2/G3/G4: all RED — current state emits msArrayRefDestroy for
// Function/Union/Distinct elements, which is the silent-corruption bug.
// Post-Phase-G: all GREEN — each TypeKind routes to its appropriate
// per-element destroy.

import { firstArrayDestroyEmitted, compilesCleanly } from "../helpers";

// ===== Function (closure) element =====

const SRC_CLOSURE = `
function makeFns(): (() => int32)[] {
	const fns: (() => int32)[] = [];
	let i: int32 = 0 as int32;
	while (i < (3 as int32)) {
		const x = i;
		fns.push(() => x);
		i = (i + (1 as int32)) as int32;
	}
	return fns;
}
function main(): void {
	const fns = makeFns();
	console.log(fns.length.toString());
}
main();
`;

test "bug3.closure: compiles cleanly" {
	assert compilesCleanly(SRC_CLOSURE);
}

test "bug3.closure: must NOT emit msArrayRefDestroy (silent-corruption catch-all)" {
	const destroy = firstArrayDestroyEmitted(SRC_CLOSURE);
	// Closure array stores msClosure structs INLINE (16B stride). Routing
	// to msArrayRefDestroy reads them as void* (8B stride) → misaligned
	// access at cleanup. Crash repro: /tmp/audit-probe/loop-closure.ms.
	if (destroy === "msArrayRefDestroy(") {
		assert false, "BUG #3: closure[] silently routed to msArrayRefDestroy — runtime crash imminent";
	}
	assert true;
}

// ===== Union (raw string-discriminated DU) element =====

const SRC_UNION = `
type U = { tag: "a", v: int32 } | { tag: "b", s: string };
function makeUs(): U[] {
	const us: U[] = [];
	us.push({ tag: "a", v: 1 });
	us.push({ tag: "b", s: "hello" });
	return us;
}
function main(): void {
	const us = makeUs();
	console.log(us.length.toString());
}
main();
`;

test "bug3.union: compiles cleanly" {
	assert compilesCleanly(SRC_UNION);
}

test "bug3.union: must NOT emit msArrayRefDestroy" {
	const destroy = firstArrayDestroyEmitted(SRC_UNION);
	// Union element is variable-stride struct, msArrayRefDestroy reads
	// each as void* — leaks inner refs, may crash on realistic data.
	if (destroy === "msArrayRefDestroy(") {
		assert false, "BUG #3 family: Union[] silently routed to msArrayRefDestroy — inner refs leak / crash";
	}
	assert true;
}

// ===== Distinct (nominal wrapper) element =====

const SRC_DISTINCT = `
distinct type UserId = int32;
function makeIds(): UserId[] {
	const ids: UserId[] = [];
	ids.push(1 as int32 as UserId);
	ids.push(2 as int32 as UserId);
	return ids;
}
function main(): void {
	const ids = makeIds();
	console.log(ids.length.toString());
}
main();
`;

test "bug3.distinct: compiles cleanly" {
	assert compilesCleanly(SRC_DISTINCT);
}

test "bug3.distinct: must NOT emit msArrayRefDestroy" {
	const destroy = firstArrayDestroyEmitted(SRC_DISTINCT);
	// distinct int32 has 4B stride. msArrayRefDestroy iterates len times
	// at 8B stride → buffer overflow → SIGSEGV under stress.
	if (destroy === "msArrayRefDestroy(") {
		assert false, "BUG #3 family: Distinct[] silently routed to msArrayRefDestroy — SIGSEGV imminent";
	}
	assert true;
}
