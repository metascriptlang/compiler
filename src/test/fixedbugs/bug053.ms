// bug053 — macro-body check errors swallowed by on-demand helper compiles
//
// Symptom:    a macro body with a genuine type error (bogus member read)
//             compiles CLEAN whenever the body also calls a module-level
//             helper function. std/serialize macros (jsonValueOf et al.) ride
//             this hole: their nodeType reads were rejected by the engine
//             checker, but the diagnostics vanished.
//
// Root:       _lastEngineCheckErrors is a module-global slot written by every
//             transformForEngine call. appendProgramToImage triggers on-demand
//             helper compiles (ensureCompiledIntoEngine) AFTER the wrapper's
//             own check, and the helper's clean compile overwrites the slot
//             before compileMacroIntoEngine reads it (eval.ms:157).
//
// Fix:        compileProgramIntoEngine snapshots the slot right after its own
//             transformForEngine and restores it after appendProgramToImage,
//             so nested on-demand compiles cannot clobber the caller's errors.

import { compileToCWithStd } from "../helpers";

const srcSwallowed = `
import { Node, NodeKind } from "std/meta";

export function helper(n: Node): string { return "x"; }

export macro bad(t: Node): Node {
	const z = t.thisFieldDoesNotExistAnywhere;
	let s: string = "";
	if (s === "__never__") {
		s = helper(t);
	}
	return { kind: NodeKind.StringLiteral, line: t.line, column: t.column, value: s };
}

function main(): void {
	const x: string = bad(1);
	console.log(x);
}
`;

test "bug053: macro body type error survives an on-demand helper compile" {
	const c = compileToCWithStd(srcSwallowed);
	assert !c.ok;
	assert c.error.indexOf("thisFieldDoesNotExistAnywhere", 0) >= 0;
}
