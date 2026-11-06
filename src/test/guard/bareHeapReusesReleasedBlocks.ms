// GUARD-OS bare --mm=manual
// GUARD-ASAN
@compile("./fixtures/bareHeapChecks.c");
@compile("./fixtures/bareHeapOtherUnit.c");
@include("./fixtures/bareHeapChecks.h");

extern function msBareHeapReuseChecks(): int32;

const failedCase = msBareHeapReuseChecks();
if (failedCase != 0) {
	throw new Error(`bare heap contract failed: case ${failedCase}`);
}
console.log("GUARD-OK");
