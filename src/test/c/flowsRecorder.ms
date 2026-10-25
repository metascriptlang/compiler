// Pins the flow recorder: every C pass writes its row. The phase rows of a whole build are pinned by
// src/test/nativeBuildBoundary.ms group flows, which runs the candidate compiler.

import { env } from "std/process";
import { readFile, remove } from "std/fs";
import { flowAddMs, flowRowsText, flowsEnable, flowsWrite } from "../../compiler/flows";
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

test "flowsWrite appends each build's rows to the MSC_FLOWS file and starts the next build empty" {
	const file = `${env.get("TMPDIR") != "" ? env.get("TMPDIR") : "/tmp"}/msc-flows-write-pin.tsv`;
	remove(file);
	env.set("MSC_FLOWS", file);
	flowsEnable(true);
	flowAddMs("cc", 2);
	flowsWrite();
	flowAddMs("cc", 3);
	flowsWrite();
	flowsEnable(false);
	env.delete("MSC_FLOWS");
	const read = readFile(file);
	assert read.ok;
	assert read.value == "msc\tcc\tms\t2\nmsc\tcc\tcount\t1\nmsc\tcc\tms\t3\nmsc\tcc\tcount\t1\n";
}
