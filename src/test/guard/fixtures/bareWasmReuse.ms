@compile("./bareHeapChecks.c");
@compile("./bareWasmMulOverflow.c");
@compile("./bareWasmLibcChecks.c");
@compile("./bareHeapOtherUnit.c");
@include("./bareHeapChecks.h");

extern function msBareHeapReuseChecks(): int32;

const failedCase = msBareHeapReuseChecks();
if (failedCase != 0) {
	throw new Error(`bare Wasm heap contract failed: case ${failedCase}`);
}
