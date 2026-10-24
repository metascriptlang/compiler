// Pins the flow recorder: every C pass writes its row, and one build writes the phase rows.

import { env, execFileCapture } from "std/process";
import { ensureDir, readFile, remove, writeFile } from "std/fs";
import { flowRowsText, flowsEnable } from "../../compiler/flows";
import { compileToC } from "../helpers";

const C_PASSES = [
	"eraseBrandTypes", "planModuleTdz", "lowerBorrow", "lowerImplicitConv", "lowerAssert", "lowerDefer",
	"lowerConstFold", "lowerStaticInit", "lowerVoidBind", "lowerObjectSpread", "lowerArraySpread",
	"lowerStringConcatFlatten", "lowerOptionalChain", "lowerNullishCoalesce", "materializeMaybeReads",
	"lowerStringTruthiness", "lowerRestParams", "lowerDestructuring", "lowerForLoop", "lowerForOf",
	"lowerTryExpr", "lowerResultConstructors", "lowerTypeof", "lowerSwitch", "lowerMatch", "lowerTryExpr#2",
	"retargetJumps", "lowerTailCall", "lowerParamReassign", "lowerAwaitSpill", "lowerNamespaceValues",
	"lowerActorPre", "lowerSpawnGroup", "lowerPointerAddresses", "lowerAsync", "lowerAsyncBridge",
	"lowerGenerator", "lowerSpawn", "lowerAwaitSpill#2", "lowerAwait", "lowerFieldInitializers", "lowerActor",
	"lowerVarHoist", "lowerRvalueBridge", "lowerExtensionMethod", "lowerCtorInit", "lowerNewExpr",
	"lowerMethodToFunction", "lowerLambda", "lowerUnionConversions", "lowerCallHoist", "lowerBuiltins",
	"lowerCStringConv", "lowerClosureEqualities", "lowerOperators", "lowerBigIntOps", "lowerStringOps",
	"spanLower", "lowerConditionalExpr", "spanLower#2", "spanParamExpand", "lowerNewExpr#2", "lowerUpdateExpr",
	"lowerNullable", "projectNarrowedUnions", "lowerBitSet", "lowerDCE", "liftDestructors",
	"markClosureCalls", "native.lowerNumberBitwiseOperands", "injectRangeChecks", "injectIntChecks",
	"coerceOptionals", "native.lowerBuiltins", "native.lowerStringOps", "native.lowerEnumToString",
	"lowerDownConversions", "insertVarParamDerefs", "lowerInductionPointers",
];

function rowValue(text: string, flow: string, metric: string): number {
	for (const line of text.split("\n")) {
		const cols = line.split("\t");
		if (cols.length == 4 && cols[0] == "msc" && cols[1] == flow && cols[2] == metric) return parseFloat(cols[3]);
	}
	return -1;
}

function rowCount(text: string, flow: string): number {
	let n = 0;
	for (const line of text.split("\n")) {
		const cols = line.split("\t");
		if (cols.length == 4 && cols[1] == flow && cols[2] == "count") n = n + 1;
	}
	return n;
}

test "every pass of the C pipeline writes exactly one row" {
	flowsEnable(true);
	const c = compileToC("const x: number[] = [1, 2]; console.log(x.length);");
	const text = flowRowsText();
	flowsEnable(false);
	assert c.ok;
	for (const pass of C_PASSES) assert rowCount(text, `pass.${pass}`) == 1;
	assert rowValue(text, "pass.lowerPowerAssert", "count") < 0;
	assert rowValue(text, "analyze.inject", "count") == 1;
}

test "a build writes its phase rows, and the passes fit inside phase A" {
	const compiler = env.get("MSC") != "" ? env.get("MSC") : "msc";
	const dir = `${env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp"}/msc-flows-pin`;
	ensureDir(dir);
	const flows = `${dir}/flows.tsv`;
	remove(flows);
	assert writeFile(`${dir}/probe.ms`, "console.log(1 + 2);\n").ok;
	env.set("MSC_FLOWS", flows);
	const built = execFileCapture(compiler, ["build", `${dir}/probe.ms`, "--emit=c", `--output=${dir}/out`]);
	env.delete("MSC_FLOWS");
	assert built.ok;
	const read = readFile(flows);
	assert read.ok;
	const text = read.value;
	let passMs: number = 0;
	for (const line of text.split("\n")) {
		const cols = line.split("\t");
		if (cols.length == 4 && cols[1].startsWith("pass.") && cols[2] == "ms") passMs = passMs + parseFloat(cols[3]);
	}
	assert rowValue(text, "total", "ms") > 0;
	assert rowValue(text, "phase.setup", "ms") > 0;
	assert rowValue(text, "phase.A", "ms") > 0;
	assert passMs > 0 && passMs <= rowValue(text, "phase.A", "ms");
	assert rowValue(text, "emit.module", "ms") > 0;
	assert rowValue(text, "a2.xform", "count") > 0;
}
