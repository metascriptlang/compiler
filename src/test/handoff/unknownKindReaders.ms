// Phase 0 guard for the TypeKind.Unknown kind-split debt — docs/UNKNOWN-BUG.md.
//
// Two holes were found by probe on 2026-08-04 and had NO test, so a refactor
// could change either one silently:
//
//   §3 — three readers disagree about whether a flagless Unknown is a pointer:
//        emission says void*, the checker's conversion gate says pointer-shaped,
//        the arg shim says not-a-pointer. That disagreement is the mechanism
//        bug076 used, and it is still in the tree.
//   §4.1 — a generic whose T is not inferrable reaches codegen with no checker
//        diagnostic and emits a call to a specialisation that was never emitted.
//
// Cells marked DEBT pin behaviour that is WRONG ON PURPOSE: they record today's
// answer so the split cannot happen quietly. When §8 Phase 2 lands they must be
// rewritten to assert agreement, not disagreement — that is the point.

import { unknownType, userUnknownType, isUserUnknown, isPointerShapedForUnknown } from "../../checker/types";
import { isPointerType } from "../../codegen/c/types";
import { hasErrors } from "../../checker/context";
import { checkSource } from "./helpers";
import { compileToC } from "../helpers";

// ===== A. user `unknown` — all three readers must agree it is a pointer =====

test "user unknown carries the UserUnknown stamp" {
	assert isUserUnknown(userUnknownType());
}

test "checker reader: user unknown is pointer-shaped" {
	assert isPointerShapedForUnknown(userUnknownType());
}

test "ABI reader: user unknown is a pointer" {
	assert isPointerType(userUnknownType());
}

test "emission reader: a user unknown param is declared void*" {
	// Match the parameter itself, not a bare "void*" — prelude structs are full
	// of void* fields and would make a substring test pass for free.
	const c = compileToC("function f(x: unknown): void { }\nfunction main(): void { f(null as unknown); }");
	assert c.ok;
	if (c.ok) { assert c.value.contains("(void* x)"); }
}

test "emission reader: the call passes the value, not its address" {
	// The argument must be a LOCAL, not `null as unknown`: a literal has no
	// address to take, so a version of this cell built on one can never go red.
	// Scoped to the lines that mention f — a module-wide search for "&" matches
	// unrelated prelude code and fails for free.
	const c = compileToC("class Box { n: number; }\nfunction f(x: unknown): void { }\nfunction main(): void { const b = new Box(); const u = b as unknown; f(u); }");
	assert c.ok;
	if (c.ok) {
		for (const ln of c.value.split("\n")) {
			if (ln.contains("f__") && ln.contains("&")) {
				assert false, "address taken for a void* param — the bug076 shape: " + ln;
			}
		}
	}
}

// ===== B. flagless Unknown — DEBT: the readers do not agree =====

test "flagless Unknown carries no stamp" {
	assert !isUserUnknown(unknownType());
}

test "DEBT: checker and ABI readers disagree about a flagless Unknown" {
	// After the §8 Phase 2 split this cell must become: both readers answer
	// false for TypeKind.Pending. Until then the disagreement IS the state of
	// the tree and is pinned here so it cannot change unnoticed.
	const pending = unknownType();
	assert isPointerShapedForUnknown(pending), "checker reader changed — update docs/UNKNOWN-BUG.md §3";
	assert !isPointerType(pending), "ABI reader changed — update docs/UNKNOWN-BUG.md §3";
}

// ===== C. the stamp survives an alias (§4 — must stay true across the split) =====

test "alias of unknown still rejects a value-typed argument" {
	const src = "type A = unknown;\nfunction take(x: A): void { }\nfunction main(): void { const s: string = \"hi\"; take(s as A); }";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert hasErrors(ctx);
}

test "a string cast to unknown is rejected at the binding" {
	const src = "function main(): void { const u: unknown = \"hi\" as unknown; }";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert hasErrors(ctx);
}

test "control: a pointer-shaped value passes through the same alias" {
	// Without this cell the two rejections above would also pass if the source
	// were malformed for an unrelated reason. Same alias, same call, but a Ref —
	// which has a void* repr — so it must be accepted.
	const src = "class Box { n: number; }\ntype A = unknown;\nfunction take(x: A): void { }\nfunction main(): void { const b = new Box(); take(b as A); }";
	const ctx = checkSource(src);
	assert ctx !== null;
	assert !hasErrors(ctx);
}

// ===== D. §4.1 — an uninferrable generic reaches codegen =====

test "DEBT: uninferrable T is not diagnosed and reaches codegen" {
	// Desired behaviour after the split: c.ok === false with a "cannot infer T"
	// diagnostic. Today the checker is silent and codegen emits a CALL to a
	// specialisation that is never declared or defined — exactly one line in the
	// whole module mentions it — so the failure surfaces in the C compiler as
	// "call to undeclared function". Flipping this cell is the acceptance test.
	// Counting how often the symbol is mentioned proves nothing — a correctly
	// specialised call is mentioned exactly as often. The discriminator is that
	// T is never bound into the symbol name, and the local falls back to the
	// generic Ref repr instead of the element-typed one.
	const un = compileToC("function mk<T>(): T[] { return []; }\nfunction main(): void { const a = mk(); }");
	const ex = compileToC("function mk<T>(): T[] { return []; }\nfunction main(): void { const a = mk<number>(); }");
	assert un.ok, "uninferrable T is now diagnosed — flip this cell, see docs/UNKNOWN-BUG.md §4.1";
	assert ex.ok;
	if (un.ok && ex.ok) {
		assert ex.value.contains("mk__number__"), "control: an explicit targ must bind T into the symbol name";
		assert ex.value.contains("msNumberArray* a_1_"), "control: an explicit targ must pick the element-typed repr";
		assert !un.value.contains("mk__number__"), "T is now bound — §4.1 changed";
		assert un.value.contains("msRefArray* a_1_"), "the unbound-T fallback repr changed — §4.1 changed";
	}
}
