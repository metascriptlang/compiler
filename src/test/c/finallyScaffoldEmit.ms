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
