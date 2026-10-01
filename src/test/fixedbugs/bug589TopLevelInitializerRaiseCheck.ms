// bug589 — a module-level initializer that raised let the next statement run
//
// Symptom:    `const v = f();` followed by a console.log of v at the top level of a
//             module printed `after v=0` before reporting f's exception; inside a
//             function the same two statements stopped at the throw.
// Root cause: codegen/c genGlobalVar emitted `v = f();` into Init000 without the
//             raise check every statement in a proc gets (emitCallRaiseCheck), and
//             so did the module-level temps the DRC pass hoists out of a statement.
// Fix:        genGlobalVar runs emitCallRaiseCheck on the initializer, so Init000
//             leaves through BeforeRet_ like any proc (the reference's init proc is
//             an ordinary proc with the same checks).

import { compileToCWithStd } from "../helpers";

function initBody(c: string): string {
	const at = c.indexOf("__Init000(void) {");
	if (at < 0) return "";
	const end = c.indexOf("\n}", at);
	return c.slice(at, end);
}

test "bug589: a raising global initializer is followed by a raise check" {
	const c = compileToCWithStd(`function f(): int32 { throw new Error("stop"); }
const v = f();
console.log(\`after v=\${v}\`);`);
	assert c.ok, c.ok ? "" : c.error;
	const body = initBody(c.value);
	const call = body.indexOf("_u0();");
	assert call > 0, body;
	assert body.slice(call, body.indexOf("\n", body.indexOf("\n", call) + 1)).includes("if (msErr) goto BeforeRet_;"), body;
	assert body.includes("BeforeRet_: ;"), body;
}

test "bug589: a hoisted module temp carrying a raising call is checked too" {
	const c = compileToCWithStd(`function f(): int32 { throw new Error("stop"); }
console.log(\`v=\${f()}\`);`);
	assert c.ok, c.ok ? "" : c.error;
	const body = initBody(c.value);
	const call = body.indexOf("_u0()");
	assert call > 0, body;
	const next = body.indexOf("\n", call);
	assert body.slice(next, body.indexOf("\n", next + 1)).includes("if (msErr) goto BeforeRet_;"), body;
}
