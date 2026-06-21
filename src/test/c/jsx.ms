// E2E: JSX leak guard — a JSX expression that no macro consumes is a compile-time `Node`
// reaching codegen. The checker must reject it with a clear diagnostic instead of letting
// codegen emit invalid C (`/* unsupported expression: kind=85 */`). The consumed path
// (a macro reading the JSX `Node`) is covered natively by native/programs/jsxMacroNative.ms.

import { compileToC } from "../helpers";

test "E2E C: unconsumed JSX element is rejected by the checker" {
	const c = compileToC("function f(): void { const x = <a/>; }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: unconsumed JSX fragment is rejected by the checker" {
	const c = compileToC("function f(): void { const x = <></>; }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: unconsumed JSX as a bare statement is rejected" {
	const c = compileToC("function f(): void { <a/>; }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: nested unconsumed JSX is rejected without leaking children to codegen" {
	const c = compileToC("function f(): void { const x = <a><b/><c/></a>; }");
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("consumed by a macro");
		assert !c.error.contains("kind=");
	}
}
