import { compileToC, compileToJS, raiserErrors, refusedOnEveryBackend } from "../helpers";

test "comptimeStatement: a statement block that fails the check is a compile error at the block" {
	const narrowed = refusedOnEveryBackend("@comptime { const i: int32 = 300; console.log(`ct ${i as int8}`); }\nconsole.log(\"main\");", "cannot convert 300 to int8");
	assert narrowed == "", narrowed;
	const mistyped = refusedOnEveryBackend("@comptime { const s: string = 5; console.log(s); }\nconsole.log(\"main\");", "is not assignable to type 'string'");
	assert mistyped == "", mistyped;
}

test "comptimeStatement: a statement block that passes the check leaves nothing to compile" {
	const source = "@comptime { const n: int32 = 2; console.log(`ct ${n * 21}`); }\nconsole.log(\"main\");";
	const c = compileToC(source);
	assert c.ok, c.ok ? "" : c.error;
	const js = compileToJS(source);
	assert js.ok, js.ok ? "" : js.error;
	assert !js.value.includes("ct 42"), js.value;
	assert raiserErrors(source) == "", raiserErrors(source);
}

test "comptimeStatement: a block that fails the check is not run" {
	const source = "const x: int32 = @comptime { const s: string = 5; throw new Error(\"the body ran\"); };\nconsole.log(`${x}`);";
	const c = compileToC(source);
	assert !c.ok && c.error.includes("is not assignable to type 'string'"), c.ok ? "accepted" : c.error;
	assert !c.error.includes("the body ran"), c.error;
}
