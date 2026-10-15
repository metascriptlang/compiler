import { compileToC, compileToJS } from "../helpers";
import { parseSource } from "../../parser/statements/validation";
import { checkProgramWithRegistry, preludeContextFor } from "../../checker/checkPass";
import { CheckerContext, Severity, ExportRegistry } from "../../checker/context";
import { Module, ModuleGraph } from "../../module/graph";
import { resetBuildState } from "../../compiler/buildSession";

function raiserErrors(source: string): string {
	resetBuildState();
	const pr = parseSource(source);
	if (!pr.ok) return "parse failed";
	const ctx: CheckerContext = checkProgramWithRegistry(pr.value, null as unknown as ExportRegistry, null as unknown as ModuleGraph, null as unknown as Module, preludeContextFor("", ".rms"));
	let text = "";
	for (const e of ctx.errors) {
		if (e.severity == Severity.Error) text = text + e.message + "\n";
	}
	return text;
}

function refusedOnEveryBackend(source: string, needle: string): string {
	const c = compileToC(source);
	if (c.ok || !c.error.includes(needle)) return "C: " + (c.ok ? "accepted" : c.error);
	const js = compileToJS(source);
	if (js.ok || !js.error.includes(needle)) return "JS: " + (js.ok ? "accepted" : js.error);
	const raiser = raiserErrors(source);
	if (!raiser.includes(needle)) return "Raiser: " + (raiser == "" ? "accepted" : raiser);
	return "";
}

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
