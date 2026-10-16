// Parked at inbox card 2026-10-03-generic-class-with-no-generic-field-is-not-a-template.md

import { compileToC } from "../helpers";

test "slot relation: contextual fitting survives generic bodies and expression contexts" {
	const cases = [
		{ name: "unused generic body with a contextually typed empty array field", source: "interface Op<T> { v: T; } interface Queue<T> { ops: Op<T>[]; reset: boolean; } class Host<T> { attach(): Queue<T> { const q: Queue<T> = { ops: [], reset: false }; return q; } }\n" },
	];
	for (const item of cases) {
		const c = compileToC(item.source);
		assert c.ok, item.name + (c.ok ? "" : ": " + c.error);
	}
}
