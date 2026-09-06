// @stdout: unannotated all-ok
// A function with no return-type annotation and no `return` statement must
// infer `void`, exactly as one whose body returns a value infers that type.
// The sentinel used to survive into the function's type and trip codegen's
// unknown-type gate (kind Inferred) at every call site on the C backend.

let trace = "";
function mark(m: string) { trace = trace + m; }

mark("a");
function markB() { mark("b"); }
markB();
function bareRet() { if (trace.length > 0) { return; } mark("X"); }
bareRet();
function makeNum(x: number) { return x * 2; }
const n = makeNum(21);
const arrow = () => { mark("c"); };
arrow();

function finish(): void {
	if (trace == "abc" && n == 42) { console.log("unannotated all-ok"); }
	else { console.log("FAIL trace=" + trace + " n=" + n.toString()); }
}
finish();
