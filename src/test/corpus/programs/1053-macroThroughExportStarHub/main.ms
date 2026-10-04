// @stdout: 42 42
// @exit: 0
// note: two macros reach the program only through an `export *` hub: one used at top level, one `try`d inside a function. A macro re-exported by `export *` used to stay unexpanded (C: "MacroInvocation reached C codegen unlowered"; JS: a syntax error), and the `try` form left every later use typed `<error>`.

import { fortyTwo, tried } from "./hub";

function viaTry(): Result<int32, string> {
	const v = try tried();
	return Result.ok(v + 1);
}

const top: int32 = fortyTwo();
const r = viaTry();
if (r.ok) { console.log(top.toString() + " " + r.value.toString()); }
