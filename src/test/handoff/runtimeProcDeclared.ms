// The checker declares, in the system module, every runtime routine the lowerings
// synthesize a call to; a lowering reads the declared symbol and a name nobody
// declared stops the build.

import { standalonePreludeCtx } from "../../checker/checkPass";
import { compileToC } from "../helpers";

function undeclared(backendExt: string, names: string[]): string[] {
	const declared = standalonePreludeCtx(backendExt).compilerFuncs;
	const missing: string[] = [];
	for (const name of names) {
		if (!declared.has(name)) missing.push(name);
	}
	return missing;
}

test "the C prelude declares every runtime routine the lowerings synthesize" {
	const names: string[] = [
	"__FILE__", "msActorCreatePid", "msActorFromPid", "msActorPollAll", "msActorRegister", "msActorSend",
	"msActorSuspend", "msArrayCopy", "msArrayDestroy", "msArrayNumberSink", "msArrayNumberWasMoved",
	"msArrayRefCopy", "msArrayRefDestroy", "msArrayRefSink", "msArrayRefWasMoved", "msArraySetLen",
	"msArrayStringCopy", "msArrayStringDestroy", "msArrayStringSink", "msArrayStringWasMoved",
	"msArrayUint8Copy", "msArrayUint8Destroy", "msArrayUint8Sink", "msArrayUint8WasMoved", "msArrayWasMoved",
	"msAsyncStart", "msAtomicDecref", "msAtomicIncref", "msAwaitGroupBlocking",
	"msAwaitGroupBlockingWithDeadline", "msAwaitGroupCancel", "msAwaitGroupCheckFailed", "msAwaitGroupFree",
	"msAwaitGroupInit", "msAwaitGroupResult", "msAwaitGroupSetDoneFut", "msAwaitGroupTimedOut",
	"msAwaitSlotCreate", "msAwaitSlotRelease", "msAwaitSlotWait", "msBigIntAdd", "msBigIntAnd", "msBigIntCmp",
	"msBigIntDiv", "msBigIntFromFloat64", "msBigIntFromLit", "msBigIntIsZero", "msBigIntMod", "msBigIntMul",
	"msBigIntNeg", "msBigIntNot", "msBigIntOr", "msBigIntPow", "msBigIntShl", "msBigIntShr", "msBigIntSub",
	"msBigIntToFloat64", "msBigIntToInt64", "msBigIntToString", "msBigIntXor", "msBoolToString", "msBoxDouble",
	"msBoxInt32", "msBoxInt64", "msCheckRangeI16", "msCheckRangeI32", "msCheckRangeI64", "msCheckRangeI8",
	"msClosureArrayDestroy", "msClosureCopy", "msClosureDestroy", "msClosureSink", "msClosureTrace",
	"msClosureWasMoved", "msDecref", "msDecrefCyclic", "msDivAssignI32", "msDivI32", "msDivI64", "msDivU32",
	"msDivU64", "msFutureCheckErr", "msFutureComplete", "msFutureCompleteVoid", "msFutureCreate",
	"msFutureDrcDestroy", "msFutureFail", "msFutureFinished", "msFutureRead", "msFutureReadBool",
	"msFutureReadDouble", "msFutureReadInt32", "msFutureReadString", "msFutureThen_double",
	"msFutureThen_int32", "msFutureThen_msString", "msFutureThen_ref", "msIncref", "msIncRef", "msIncrefCyclic",
	"msIntToString", "msIntToStringRadix", "msModI32", "msMonoTimeMs", "msMsgAllocSized", "msMsgGetDouble",
	"msMsgGetPtr", "msMsgGetString", "msMsgKind", "msMsgReplyFuture", "msMsgSetDouble", "msMsgSetPtr",
	"msMsgSetPtrShared", "msMsgSetString", "msNumberArrayDestroy", "msNumberArraySetLen", "msNumberToString",
	"msNumberToStringRadix", "msOrcBeginTeardown", "msOrcEndTeardown", "msOrcTraceRef", "msPowI32", "msPowI64",
	"msPrintln", "msPtrWasMoved", "msRaiseFieldError", "msRefArrayDestroy", "msRefArraySetLen", "msRefCopyCyclic", "msSetCard32",
	"msSetHashWord", "msSliceLen", "msSpawn", "msSpawnSlotSubmit", "msSpawnTaskSubmit", "msStringAppend",
	"msStringAppendChar", "msStringAppendCodePoint", "msStringArrayDestroy", "msStringArraySetLen", "msStringByteAt", "msStringByteLength",
	"msStringCompare", "msStringConcat", "msStringCopy", "msStringDecref", "msStringEquals", "msStringHash", "msStringIncref",
	"msStringLength", "msStringSink", "msStringToCString", "msStringWasMoved", "msToInt32", "msUint64ToString",
	"msUint64ToStringRadix", "msUnboxDouble", "msUnboxInt32", "msUnboxString", "msWaitFor", "msWaitForReady"
	];
	assert undeclared(".cms", names).length == 0, undeclared(".cms", names).join(" ");
}

test "the JS prelude declares every runtime routine the lowerings synthesize" {
	const names: string[] = [
	"msSpanValues", "msChkIndex", "msChkArray", "msSpanAt", "msArrayAt", "msSpanCell", "msArrayCell",
	"msSpanOf", "msSliceSpan", "msSliceOf", "msDivI32", "msDivI64", "msDivU32", "msDivU64", "msModI32",
	"msModI64", "msModU32", "msModU64", "msPowI32", "msPowI64", "msPowU32", "msPowU64", "msStringLength",
	"charAt", "msStringByteAt", "msStringByteLength", "msStringHash", "msIntToString", "asBytes", "byteLength",
	"msSetCard32", "msPrintln", "__paBegin", "__paEnd", "__paValueStr", "__paValueNum", "__paValueInt",
	"__paValueBool"
	];
	assert undeclared(".jms", names).length == 0, undeclared(".jms", names).join(" ");
}

test "a lowering that needs a routine nobody declared stops the build" {
	assert undeclared(".cms", ["msNoSuchRuntimeRoutine"]).length == 1;
}

test "bigint arithmetic, a narrowing cast and a Promise.all compile through the declared routines" {
	const src = `
function narrowed(wide: number): int32 { return wide as int32; }
async function run(): Promise<void> {
	const a = 2n;
	const b = a * 3n + 1n;
	const narrow = narrowed(300);
	const ps: Promise<int32>[] = [Promise.resolve(narrow)];
	const all = await Promise.all(ps);
	console.log(b.toString(), all.length);
}
await run();
`;
	const r = compileToC(src);
	assert r.ok, r.ok ? "" : r.error;
	assert r.value.indexOf("msBigIntMul") >= 0;
	assert r.value.indexOf("msCheckRangeI32") >= 0;
	assert r.value.indexOf("msPromiseAllFor_msFuture_int32") >= 0;
}
