// bug122 — `await` inside a `test` block is a SyntaxError on the js lane
//
// Symptom:    `msc test file.ms --target=js` died at node module load:
//             "SyntaxError: Unexpected reserved word" pointing at the `await`
//             line. emitTestDecl had mirrored the C wrapper's plain shape —
//             `export function __ms_test_N() { ... await ... }` — and js has
//             no blocking await: the wrapper must be async. The C lane ran the
//             same body fine (its test runner owns the event loop), so the gap
//             only surfaced on js. Found via Neon's press.test.ms, whose
//             gesture cells await real std timers.
// Root cause: two halves — js/test.ms emitted a non-async wrapper, and the js
//             test harness (jsTestHarnessSource) called each cell
//             synchronously, so making the wrapper async alone would have
//             turned every test into an unawaited promise.
// Fix:        emitTestDecl emits `export async function` (uniform — a sync
//             body costs nothing), and the harness awaits every cell; a sync
//             throw surfaces identically through the rejection.

import { compileTestBuildToJS } from "../helpers";

const b120 = `
import { sleepAsync } from "std/core/promise";
test "await inside a test block" {
	await sleepAsync(1);
	assert true, "unreachable";
}
`;

test "bug122: a js test wrapper is emitted async so await is legal" {
	const out = compileTestBuildToJS(b120);
	assert out.ok;
	if (out.ok) {
		assert out.value.contains("export async function __ms_test_0"), "wrapper must be async";
	}
}
