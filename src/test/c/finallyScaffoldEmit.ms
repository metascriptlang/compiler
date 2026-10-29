// E2E C: a finally the error flag cannot reach runs bare; one that can keeps the
// save/clear/restore scaffold.

import { compileToC } from "../helpers";

function emit(src: string): string {
	const c = compileToC(src);
	return c.ok ? c.value : "";
}

const RAISER = "function boom(): void { throw new Error(\"x\"); }\n";

test "E2E C: a finally of never-raising calls emits no error scaffold" {
	const c = emit(RAISER + `
		function main(): void {
			try { boom(); } finally { console.log("done"); }
		}
		main();
	`);
	assert c != "";
	assert c.contains("__finally_");
	assert !c.contains("__finraise_");
	assert !c.contains("__oldErr_");
}

test "E2E C: a finally that calls a raising routine keeps the error scaffold" {
	const c = emit(RAISER + `
		function main(): void {
			try { boom(); } finally { boom(); }
		}
		main();
	`);
	assert c.contains("__finraise_");
	assert c.contains("__oldErr_");
}

test "E2E C: a finally that calls a user routine keeps the error scaffold" {
	const c = emit(RAISER + `
		function quiet(): void { console.log("q"); }
		function main(): void {
			try { boom(); } finally { quiet(); }
		}
		main();
	`);
	assert c.contains("__finraise_");
}

test "E2E C: a finally that returns keeps the error scaffold that drops the exception in flight" {
	const c = emit(RAISER + `
		function main(): int32 {
			try { boom(); } finally { return 5; }
		}
		console.log(main());
	`);
	assert c != "";
	assert c.contains("__oldErr_");
}

const HOOKS = `
class Plain { n: int32 = 1; }
function onDestroy(this p: Plain): void { console.log(String(p.n)); }
class Guarded { n: int32 = 1; }
function onDestroy(this p: Guarded): void { try { console.log(String(p.n)); } catch (e) { console.log("c"); } }
class Nested { n: int32 = 1; }
function quietTry(n: int32): void { try { console.log(String(n)); } finally { console.log("f"); } }
function onDestroy(this p: Nested): void { quietTry(p.n); }
`;

function unwindingRelease(type: string): string {
	return emit(RAISER + HOOKS + `
		function main(): void {
			const v = new ${type}();
			boom();
		}
		main();
	`);
}

test "E2E C: unwinding through a release whose hook has neither a throw nor a try emits no error scaffold" {
	const c = unwindingRelease("Plain");
	assert c.contains("__finally_");
	assert !c.contains("__oldErr_");
}

test "E2E C: unwinding through a release whose hook holds a try, or calls a routine that does, keeps the error scaffold" {
	assert unwindingRelease("Guarded").contains("__oldErr_");
	assert unwindingRelease("Nested").contains("__oldErr_");
}
