import { compileToC } from "../helpers";

function emitted(source: string): string {
	const c = compileToC(source);
	return c.ok ? c.value : "error: " + c.error;
}

function guarded(c: string): boolean {
	return c.includes("countdollarinit") || c.includes("msModuleBindingUninitialized");
}

test "module TDZ: a binding read in a function only after its declaration runs carries no flag and no guard" {
	const c = emitted(`let count: int32 = 5;
		function bump(): void { count += 1; }
		bump();
		console.log(count);`);
	assert !c.startsWith("error: "), c.slice(0, 400);
	assert !guarded(c), c;
}

test "module TDZ: a binding read only at top level carries no flag even after an earlier call" {
	const c = emitted(`function hello(): void { console.log("hi"); }
		hello();
		let count: int32 = 5;
		console.log(count);`);
	assert !c.startsWith("error: "), c.slice(0, 400);
	assert !guarded(c), c;
}

test "module TDZ: a binding a call before its declaration can reach is flagged and guarded" {
	const c = emitted(`bump();
		let count: int32 = 5;
		function bump(): void { count += 1; }
		console.log(count);`);
	assert c.includes("countdollarinit"), c;
	assert c.includes("msModuleBindingUninitialized"), c;
}
