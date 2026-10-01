import { argv, exit } from "std/process";
import { writeStderr } from "std/io";

@include("examples/hcrProbe/hostCalls.h");

extern function hcrOpen(path: cstring): Ptr<void> from "msHcrImageOpen";
extern function hcrSymbol(handle: Ptr<void>, name: cstring): Ptr<void> from "msHcrImageSymbol";
extern function hcrClose(handle: Ptr<void>): int32 from "msHcrImageClose";
extern function hcrLastError(): uint32 from "msHcrImageLastError";
extern function hcrIsNull(value: Ptr<void>): int32 from "msHcrImageIsNull";
extern function hcrAddress(value: Ptr<void>): uint64 from "msHcrImageAddress";
extern function hcrCallProbe(raw: Ptr<void>): int32 from "msHcrImageCallProbe";
extern function openCore(path: cstring): int32 from "hcrProbeOpenCore";
extern function validateImage(handle: Ptr<void>, probe: cstring): int32 from "hcrProbeValidate";
extern function sameModule(current: Ptr<void>, candidate: Ptr<void>): int32 from "hcrProbeSameModule";
extern function sameTypes(current: Ptr<void>, candidate: Ptr<void>): int32 from "hcrProbeSameTypes";
extern function callDatInit(handle: Ptr<void>): int32 from "hcrProbeCallDatInit";
extern function callInit(handle: Ptr<void>): int32 from "hcrProbeCallInit";
extern function variableState(handle: Ptr<void>): Ptr<void> from "hcrProbeState";
extern function stageBegin(): void from "hcrProbeStageBegin";
extern function stageEnd(): void from "hcrProbeStageEnd";
extern function staged(handle: Ptr<void>): int32 from "hcrProbeStaged";
extern function commit(handle: Ptr<void>): void from "hcrProbeCommit";
extern function rollback(handle: Ptr<void>): void from "hcrProbeRollback";
extern function discard(handle: Ptr<void>): void from "hcrProbeDiscard";
extern function finalize(handle: Ptr<void>): void from "hcrProbeFinalize";

enum HcrFailureKind {
	Load,
	Symbol,
	Identity,
	Layout,
	Init,
}

struct HcrFailure {
	kind: HcrFailureKind;
	code: uint32;
}

struct HcrImage {
	handle: Ptr<void>;
	probe: Ptr<void>;
}

struct HcrModule {
	image: HcrImage;
	state: Ptr<void>;
	path: string;
}

function resolveImage(path: string): Result<HcrImage, HcrFailure> {
	const handle = hcrOpen(path);
	if (hcrIsNull(handle) != 0) {
		return Result.err({ kind: HcrFailureKind.Load, code: hcrLastError() });
	}
	if (validateImage(handle, "hcrProbeBump") == 0) {
		const code = hcrLastError();
		hcrClose(handle);
		return Result.err({ kind: HcrFailureKind.Symbol, code: code });
	}
	return Result.ok({ handle: handle, probe: hcrSymbol(handle, "hcrProbeBump") });
}

function loadInitial(path: string): Result<HcrModule, HcrFailure> {
	if (openCore(path) == 0) {
		return Result.err({ kind: HcrFailureKind.Load, code: hcrLastError() });
	}
	const resolved = resolveImage(path);
	if (!resolved.ok) return Result.err(resolved.error);
	const image = resolved.value;
	if (callDatInit(image.handle) != 0 || callInit(image.handle) != 0) {
		return Result.err({ kind: HcrFailureKind.Init, code: 0 });
	}
	return Result.ok({ image: image, state: variableState(image.handle), path: path });
}

function loadCandidate(path: string, current: HcrModule): Result<HcrModule, HcrFailure> {
	const resolved = resolveImage(path);
	if (!resolved.ok) return Result.err(resolved.error);
	const image = resolved.value;
	if (sameModule(current.image.handle, image.handle) == 0) {
		hcrClose(image.handle);
		return Result.err({ kind: HcrFailureKind.Identity, code: 0 });
	}
	if (sameTypes(current.image.handle, image.handle) == 0) {
		hcrClose(image.handle);
		return Result.err({ kind: HcrFailureKind.Layout, code: 0 });
	}
	stageBegin();
	const failed = callDatInit(image.handle);
	stageEnd();
	if (failed != 0 || staged(image.handle) == 0) {
		discard(image.handle);
		hcrClose(image.handle);
		return Result.err({ kind: HcrFailureKind.Init, code: 0 });
	}
	commit(image.handle);
	if (callInit(image.handle) != 0) {
		rollback(image.handle);
		return Result.err({ kind: HcrFailureKind.Init, code: 0 });
	}
	finalize(image.handle);
	return Result.ok({ image: image, state: variableState(image.handle), path: path });
}

function failureLabel(kind: HcrFailureKind): string {
	return match (kind) {
		HcrFailureKind.Load => "load",
		HcrFailureKind.Symbol => "symbol",
		HcrFailureKind.Identity => "identity",
		HcrFailureKind.Layout => "layout",
		HcrFailureKind.Init => "init",
	};
}

function reportFailure(path: string, failure: HcrFailure): void {
	const label = failureLabel(failure.kind);
	writeStderr("HCR: " + label + " failed for " + path + ": " + failure.code.toString() + "\n");
}

function printCall(module: HcrModule): void {
	const value = hcrCallProbe(module.image.probe);
	console.log("HCR-PROBE call " + module.path + " -> " + value.toString());
}

if (argv.length < 2) {
	writeStderr("Usage: hcrHostWindows <generation.dll> [generation.dll ...]\n");
	exit(2);
}

const initial = loadInitial(argv[1]);
if (!initial.ok) {
	reportFailure(argv[1], initial.error);
	exit(1);
}
let current = initial.value;
console.log("HCR-PROBE loaded " + current.path + " state=" + hcrAddress(current.state).toString());
printCall(current);

for (let i = 2; i < argv.length; i += 1) {
	const path = argv[i];
	const candidate = loadCandidate(path, current);
	if (candidate.ok) {
		current = candidate.value;
		const stateAddress = hcrAddress(current.state).toString();
		console.log("HCR-PROBE reloaded " + current.path + " state=" + stateAddress);
	} else {
		reportFailure(path, candidate.error);
		console.log("HCR-PROBE rejected " + path + " (" + failureLabel(candidate.error.kind) + ")");
	}
	printCall(current);
}
