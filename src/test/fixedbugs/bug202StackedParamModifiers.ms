// bug202 — a parameter with stacked modifiers refused its own element type
//
// Symptom:    `k(n)` against `sink x: Cursor<N>` failed with `got N, expected <kind:Sink>`.
// Root cause: `skipModifier` peeled one modifier layer, so `Sink<Cursor<N>>` stopped at `Cursor<N>`.
// Fix:        `skipModifier` peels every modifier layer, like the reference type skip.

import { compileToC } from "../helpers";

const src = `
interface N { k: int32; }
extern function g(x: Cursor<N>): void from "g";
extern function k(sink x: Cursor<N>): void from "k";
function run(n: N): void {
	g(n);
	k(n);
}
`;

test "bug202: a node passes a sink cursor parameter" {
	const c = compileToC(src);
	assert c.ok, c.ok ? "" : c.error;
}

test "bug202: a mismatched type still fails a sink cursor parameter" {
	const c = compileToC(src + "k(1);\n");
	assert !c.ok;
}
