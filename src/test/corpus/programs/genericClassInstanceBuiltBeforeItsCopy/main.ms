// @stdout: late: caught Cannot access 'Late' before initialization
// @stdout: main: 4 7 1
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// @xfail(esm): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a generic class instance is initialized with its generic declaration, not where the compiler places the instance's copy: a top-level call that builds one from this module or from the module that declares it runs, and only a use before the generic declaration itself throws.
import { capture } from "./cell";
class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
function make(): Box<int32> { return new Box<int32>(4); }
const made = make();
const read = capture<int32>(7);
function late(): Late<int32> { return new Late<int32>(1); }
try {
	late();
	console.log("late: built");
} catch (e) {
	console.log(`late: caught ${(e as Error).message}`);
}
class Late<T> {
	v: T;
	constructor(v: T) { this.v = v; }
}
function show(): string { return `${made.v} ${read()}`; }
console.log(`main: ${show()} ${late().v}`);
