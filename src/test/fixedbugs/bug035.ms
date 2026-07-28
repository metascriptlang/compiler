// bug035 — array of distinct type crashed with SIGSEGV at cleanup under stress
//
// Symptom:    Code like
//                 distinct type UserId = int32;
//                 const ids: UserId[] = [];
//                 ids.push(1 as int32 as UserId);
//             At small N: silently corrupted but no crash (lucky alignment).
//             Under stress (1000 iter × 10000 elements): SIGSEGV
//                 exit code 139
//
// Root cause: Same family as BUG #3 (bug033). src/analyzer/classify.ms
//             classifyArray() didn't handle `TypeKind.Distinct` element.
//             Fell into unsafe default → msArrayRefDestroy treats the
//             array as `msRefArray` (void* stride = 8B). But
//             `distinct int32` codegen uses underlying `int32_tArray`
//             (4B stride). msRefArrayDestroy iterates `arr->len` times
//             reading 8B per slot — **buffer overrun by 2x** for
//             pure int32-distinct, walking off the payload into
//             freelist metadata → SIGSEGV.
//
// Fix:        src/analyzer/classify.ms — added explicit Distinct case
//             that unwraps `elem.typeReturn` (the underlying type) and
//             recurses `classifyArray` with the unwrapped element. This
//             routes `distinct int32` through the primitive path
//             (msArrayDestroy, 4B-correct), `distinct string` through
//             msArrayStringDestroy, etc.
//
//             Nim parity: liftdestructors.nim:1063 — `of tyDistinct:
//             fillBody(c, t.elementType, body, x, y)`. Identical
//             recursive-unwrap pattern.
//
// Note: This regression uses the compile-level test pattern
//       (mirroring src/test/c/*.ms) that verifies the analyzer emits
//       the correct destroy function name. The runtime crash is
//       additionally guarded by drc_array/scenarios/bug3Family.ms
//       (bug3.distinct test).

import { compileToC } from "../helpers";

test "bug035: distinct int32 array routes to msArrayDestroy (NOT msArrayRefDestroy)" {
	const src = `
distinct type Bug035UserId = int32;
function main(): void {
	const ids: Bug035UserId[] = [];
	ids.push(1 as int32 as Bug035UserId);
	console.log(ids.length.toString());
}
main();
`;
	const result = compileToC(src);
	assert result.ok;
	if (result.ok) {
		// Pre-fix: msArrayRefDestroy would silently corrupt + SIGSEGV.
		// Post-fix: classify.ms unwraps Distinct → primitive path.
		assert result.value.indexOf("msArrayDestroy(") >= 0;
		assert result.value.indexOf("msArrayRefDestroy(") < 0;
	}
}

test "bug035: distinct string array routes to msArrayStringDestroy" {
	const src = `
distinct type Bug035Email = string;
function main(): void {
	const emails: Bug035Email[] = [];
	emails.push("a@b.c" as Bug035Email);
	console.log(emails.length.toString());
}
main();
`;
	const result = compileToC(src);
	assert result.ok;
	if (result.ok) {
		assert result.value.indexOf("msArrayStringDestroy(") >= 0;
	}
}
