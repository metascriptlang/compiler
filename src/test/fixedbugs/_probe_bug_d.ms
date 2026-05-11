// Verification probe for handoff Bug D (NOT a regression — exploratory).
// If this prints a clean MS-level "Macro 'X': msg" error, Bug D is NOT
// reproducing on the current main and was either fixed or wasn't a real
// bug to begin with. If it prints anything containing "kind=" or
// "unsupported expression", Bug D IS real and needs the
// `tryRewriteCompileError` / sentinel-propagation fix.
import { compileToC } from "../helpers";

test "Bug D probe — macro error() inline in body" {
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
	console.log(c.ok ? "BUG D: compile succeeded (expected error)" : `error: ${c.error}`);
}

test "Bug D probe — error() in nested if-else (real codec shape)" {
	// Mirrors std/serialize/json/encode.ms reject branches.
	const src = `
import { Node, NodeKind } from "std/meta";

export macro classify(t: Node): Node {
	if (t.kind === NodeKind.NumberLiteral) {
		error("number literal", t);
	} else if (t.kind === NodeKind.StringLiteral) {
		error("string literal", t);
	} else if (t.kind === NodeKind.Identifier) {
		// fall through
	} else {
		error("unsupported kind", t);
	}
	return t;
}

function main(): void {
	const a = classify(true);
}
`;
	const c = compileToC(src);
	console.log(c.ok ? "BUG D: compile succeeded (expected error)" : `error: ${c.error}`);
}
