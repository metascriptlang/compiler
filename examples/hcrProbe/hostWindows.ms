import { argv, exit } from "std/process";
import { writeStderr } from "std/io";

@include("runtime/hcr.h");

extern function hcrOpen(path: cstring): unknown from "msHcrImageOpen";
extern function hcrSymbol(handle: unknown, name: cstring): unknown from "msHcrImageSymbol";
extern function hcrClose(handle: unknown): int32 from "msHcrImageClose";
extern function hcrLastError(): uint32 from "msHcrImageLastError";
extern function hcrIsNull(value: unknown): int32 from "msHcrImageIsNull";
extern function hcrAddress(value: unknown): uint64 from "msHcrImageAddress";
extern function hcrCallHandover(raw: unknown, state: unknown): unknown from "msHcrImageCallHandover";
extern function hcrCallInit(raw: unknown): void from "msHcrImageCallInit";
extern function hcrCallProbe(raw: unknown): int32 from "msHcrImageCallProbe";

enum HcrFailureKind {
	Load,
	Symbol,
	Layout,
}

struct HcrFailure {
	kind: HcrFailureKind;
	code: uint32;
	name: string;
}

struct HcrImage {
	handle: unknown;
	handover: unknown;
	datInit: unknown;
	init: unknown;
	probe: unknown;
}

struct HcrModule {
	image: HcrImage;
	state: unknown;
	path: string;
}

function isNull(value: unknown): boolean {
	return hcrIsNull(value) != 0;
}

function loadFailure(code: uint32): HcrFailure {
	return { kind: HcrFailureKind.Load, code: code, name: "" };
}

function symbolFailure(code: uint32, name: string): HcrFailure {
	return { kind: HcrFailureKind.Symbol, code: code, name: name };
}

function layoutFailure(): HcrFailure {
	return { kind: HcrFailureKind.Layout, code: 0, name: "" };
}

function resolveImage(path: string): Result<HcrImage, HcrFailure> {
	const handle = hcrOpen(path);
	if (isNull(handle)) return Result.err(loadFailure(hcrLastError()));

	const handover = hcrSymbol(handle, "_hcr_handover");
	if (isNull(handover)) {
		const failure = symbolFailure(hcrLastError(), "_hcr_handover");
		hcrClose(handle);
		return Result.err(failure);
	}
	const datInit = hcrSymbol(handle, "DatInit000");
	if (isNull(datInit)) {
		const failure = symbolFailure(hcrLastError(), "DatInit000");
		hcrClose(handle);
		return Result.err(failure);
	}
	const init = hcrSymbol(handle, "Init000");
	if (isNull(init)) {
		const failure = symbolFailure(hcrLastError(), "Init000");
		hcrClose(handle);
		return Result.err(failure);
	}
	const probe = hcrSymbol(handle, "hcrProbeBump");
	if (isNull(probe)) {
		const failure = symbolFailure(hcrLastError(), "hcrProbeBump");
		hcrClose(handle);
		return Result.err(failure);
	}
	return Result.ok({ handle: handle, handover: handover, datInit: datInit, init: init, probe: probe });
}

function loadInitial(path: string): Result<HcrModule, HcrFailure> {
	const resolved = resolveImage(path);
	if (!resolved.ok) return Result.err(resolved.error);
	const image = resolved.value;
	const state = hcrCallHandover(image.handover, null as unknown);
	if (isNull(state)) {
		hcrClose(image.handle);
		return Result.err(layoutFailure());
	}
	hcrCallInit(image.datInit);
	hcrCallInit(image.init);
	return Result.ok({ image: image, state: state, path: path });
}

function loadCandidate(path: string, oldState: unknown): Result<HcrModule, HcrFailure> {
	const resolved = resolveImage(path);
	if (!resolved.ok) return Result.err(resolved.error);
	const image = resolved.value;
	const state = hcrCallHandover(image.handover, oldState);
	if (isNull(state)) {
		hcrClose(image.handle);
		return Result.err(layoutFailure());
	}
	hcrCallInit(image.datInit);
	return Result.ok({ image: image, state: state, path: path });
}

function reportFailure(path: string, failure: HcrFailure): void {
	if (failure.kind == HcrFailureKind.Load) {
		writeStderr("HCR: LoadLibraryA failed for " + path + ": " + failure.code.toString() + "\n");
	} else if (failure.kind == HcrFailureKind.Symbol) {
		writeStderr("HCR: GetProcAddress failed for " + failure.name + " in " + path + ": " + failure.code.toString() + "\n");
	}
}

function failureLabel(kind: HcrFailureKind): string {
	return match (kind) {
		HcrFailureKind.Load => "load",
		HcrFailureKind.Symbol => "symbol",
		HcrFailureKind.Layout => "layout",
	};
}

function printCall(module: HcrModule): void {
	console.log("HCR-PROBE call " + module.path + " -> " + hcrCallProbe(module.image.probe).toString());
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
const oldHandles: unknown[] = [];
console.log("HCR-PROBE loaded " + current.path + " state=" + hcrAddress(current.state).toString());
printCall(current);

for (let i = 2; i < argv.length; i += 1) {
	const path = argv[i];
	const candidate = loadCandidate(path, current.state);
	if (candidate.ok) {
		oldHandles.push(current.image.handle);
		current = candidate.value;
		console.log("HCR-PROBE reloaded " + current.path + " state=" + hcrAddress(current.state).toString());
	} else {
		reportFailure(path, candidate.error);
		console.log("HCR-PROBE rejected " + path + " (" + failureLabel(candidate.error.kind) + ")");
	}
	printCall(current);
}
