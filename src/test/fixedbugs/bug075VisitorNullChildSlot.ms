// bug075 — a null child slot killed the language server mid-request
//
// Symptom:    the LSP process DIED (EXC_BAD_ACCESS at 0xb8, no response, next
//             write got EPIPE) on any textDocument/completion in a file that
//             held a declaration with no initializer — `let v: uin`. Since a
//             half-typed declaration is the NORMAL state of a file being
//             edited, every editor session could hit it. Unit fixtures missed
//             it because they all gave their declarations an initializer.
// Root cause: `forEachChild` (src/ast/visitor.ms) invoked `cb` on every child
//             SLOT, including absent ones — `cb(d.initializer)` with a null
//             initializer. Consumers were written assuming a real node (Nim's
//             own invariant: absence is an `nkEmpty` NODE, never nil —
//             parser.nim:1078/1086), so `sgCheckTypeExprAt` read `.typeExpr`
//             off null. ~20 callers, one forgetting = segfault.
// Fix:        forEachChild wraps the callback and skips nulls once, centrally.
//             src/ast/childSlotGuard.ms pins the invariant going forward.

import { parseSourceLenient } from "../../parser/statements/validation";
import "../../parser/statements/core";
import { sgDetectCompletionContext, SgCompletionKind } from "../../checker/suggest";

// The cursor must sit somewhere OTHER than the annotation: with it on the
// annotation, sgCheckTypeExprAt short-circuits before the walk ever reaches the
// null slot, and the repro silently passes.
const BUG075_SRC = "conv\nlet v: uin\n";

test "bug075: completion context detection survives a decl with no initializer" {
	const pr = parseSourceLenient(BUG075_SRC);
	assert pr.ok;
	const kind = sgDetectCompletionContext(pr.value, 1, 5);
	assert kind === SgCompletionKind.Identifier;
}

test "bug075: detection is stable across every column of the broken file" {
	const pr = parseSourceLenient(BUG075_SRC);
	assert pr.ok;
	let seen = 0;
	for (let col = 1; col <= 10; col = col + 1) {
		const k = sgDetectCompletionContext(pr.value, 1, col);
		if (k === SgCompletionKind.Identifier || k === SgCompletionKind.TypeAnnotation) seen = seen + 1;
	}
	assert seen === 10;
}
