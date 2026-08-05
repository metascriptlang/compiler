// bug018 — Macro `error()` sentinel re-fires 16 times + spurious "recursive macro" warning
//
// Symptom:    A macro that calls `error("msg", t)` emits the diagnostic
//             *sixteen* times in one error string, then the checker also
//             reports "macro expansion depth limit (16) exceeded for 'X'
//             — possible recursive macro" even though the macro itself is
//             not recursive — it errored on the first call.
//
// Root cause: `expandMacroInvocation` returns the SAME `MacroInvocation`
//             node when a sentinel error is detected (after calling
//             `addError`). The two callsites in `checkExprPass` then
//             (a) overwrite `node.kind` with `expanded.kind` (no-op,
//             same node) and (b) re-run `checkExpr(node, ...)` to drive
//             type inference. Re-checking routes the still-MacroInvocation
//             back through the user-macro registry path, which re-runs
//             expand → re-fires sentinel → re-adds error → ... until
//             `macroExpansionDepth` hits the limit.
//
// Fix:        After `expandMacroInvocation` returns, if the result is
//             still `NodeKind.MacroInvocation` (= no real expansion
//             happened, error already reported), skip the re-check and
//             return `pendingType()`. Applied at both eager-call site
//             (CallExpr → user macro) and post-mono re-check site
//             (MacroInvocation in macroBodyRegistry).

import { compileToC } from "../helpers";

test "bug018: macro error() reports diagnostic exactly once, no recursive warning" {
	const src = `
import { Node, NodeKind } from "std/meta";

export macro rejectNumber(t: Node): Node {
	if (t.kind === NodeKind.NumberLiteral) {
		error("number literals not allowed", t);
	}
	return t;
}

function main(): void {
	const x = rejectNumber(42);
}
`;
	const c = compileToC(src);
	assert !c.ok;
	// Diagnostic should appear exactly once — not 16 times.
	let count = 0;
	let pos = c.error.indexOf("number literals not allowed", 0);
	while (pos >= 0) {
		count = count + 1;
		pos = c.error.indexOf("number literals not allowed", pos + 1);
	}
	assert count === 1;
	// No spurious "recursive macro" warning — rejectNumber is not recursive.
	assert c.error.indexOf("possible recursive macro", 0) < 0;
}

test "bug018: macro emitting error() preserves prefix `Macro 'name':`" {
	const src = `
import { Node, NodeKind } from "std/meta";

export macro rejectNumber(t: Node): Node {
	if (t.kind === NodeKind.NumberLiteral) {
		error("number literals not allowed", t);
	}
	return t;
}

function main(): void {
	const x = rejectNumber(42);
}
`;
	const c = compileToC(src);
	assert !c.ok;
	// Macro prefix preserved so users know which macro errored.
	assert c.error.indexOf("Macro 'rejectNumber':", 0) >= 0;
}
