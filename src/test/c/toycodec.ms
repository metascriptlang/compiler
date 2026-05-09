// E2E C: ToyCodec smoke (SERIALIZE A4 simplified proof)
//
// Day 1 — smoke test that toyEncode macro fires and returns a string at the
// call site. No real encode logic yet; just verifies the macro library is
// wired through compile pipeline.

import { compileToC } from "../helpers";

test "E2E A4 smoke: toyEncode macro fires and returns a string" {
	// Direct import — index.ms re-export doesn't propagate macro body across
	// modules (separate bug, not blocking A4). Use direct path.
	const src = `
import { toyEncode } from "std/toycodec/encode";

interface User { name: string; age: int32; }

function main(): void {
	const u: User = { name: "Alice", age: 30 };
	const s: string = toyEncode(u);
}
`;
	const c = compileToC(src);
	assert c.ok;
}
