// bug588 — a value a spawn thunk constructed itself came back read-only
//
// Symptom:    inside a spawn thunk `new Box()` had type Readonly<Box> and
//             `throw new Error("boom")` was refused ("only an 'Error' or a 'string'
//             can be thrown, got 'Readonly<Error>'"): the thunk could not write or
//             throw an object it had just made.
// Root cause: the spawn read-only boundary viewed every identifier declared
//             outside the thunk, class names included, and `new` took the view
//             from its callee.
// Fix:        only value bindings (variables, parameters, temps, modules) are
//             captures (checker/symbol.ms isCapturableValue), as the reference
//             captures only skVar/skLet/skParam/skResult/skForVar.

import { compileToCWithStd } from "../helpers";

function cError(thunkBody: string): string {
	const c = compileToCWithStd(`class Box { n: int32 = 0; }
function run(): int32 { return await spawn((): int32 => { ${thunkBody} }); }
console.log(\`\${run()}\`);`);
	return c.ok ? "compiled" : c.error;
}

test "bug588: an object the thunk constructs is writable" {
	assert cError(`const b = new Box(); b.n = 4; return b.n;`) == "compiled";
}

test "bug588: an Error the thunk constructs can be thrown" {
	assert cError(`throw new Error("boom");`) == "compiled";
}

test "bug588: an Error the thunk constructs is an Error" {
	assert cError(`const e = new Error("x"); const m: Error = e; return m.message.length;`) == "compiled";
}

test "bug588: a captured binding is still read-only" {
	const c = compileToCWithStd(`class Box { n: int32 = 0; }
function run(): int32 { const b = new Box(); return await spawn((): int32 => { b.n = 4; return b.n; }); }
console.log(\`\${run()}\`);`);
	assert !c.ok && c.error.includes("cannot write through Readonly<Box>");
}
