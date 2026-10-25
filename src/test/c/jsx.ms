// E2E: JSX leak guard — a JSX expression is a compile-time `Node`. Read as a runtime value it
// must be rejected by the checker with a clear diagnostic instead of letting codegen emit
// invalid C (`/* unsupported expression: kind=85 */`). The consumed path
// (a macro reading the JSX `Node`) is covered natively by native/programs/jsxMacroNative.ms.

import { compileToC } from "../helpers";

test "E2E C: a JSX element read as a runtime value is rejected by the checker" {
	const c = compileToC("function f(): void { const x = <a/>; console.log(x); }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: a JSX fragment read as a runtime value is rejected by the checker" {
	const c = compileToC("function f(): void { const x = <></>; console.log(x); }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: unconsumed JSX as a bare statement is rejected" {
	const c = compileToC("function f(): void { <a/>; }");
	assert !c.ok;
	if (!c.ok) { assert c.error.contains("consumed by a macro"); }
}

test "E2E C: nested JSX read as a runtime value is rejected without leaking children to codegen" {
	const c = compileToC("function f(): void { const x = <a><b/><c/></a>; console.log(x); }");
	assert !c.ok;
	if (!c.ok) {
		assert c.error.contains("consumed by a macro");
		assert !c.error.contains("kind=");
	}
}

test "E2E C: a JSX binding no macro reads never reaches codegen" {
	const c = compileToC("function f(): void { const x = <a><b/></a>; }\nf();");
	assert c.ok;
	assert !c.value.contains("unsupported expression");
}
