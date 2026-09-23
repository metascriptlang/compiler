import { argv, exit } from "std/process";

@include("runtime/hcr.h");
@include("./hostCalls.h");

extern function hcrOpen(path: cstring): unknown from "msHcrWinOpen";
extern function hcrSymbol(handle: unknown, name: cstring): unknown from "msHcrWinSymbol";
extern function hcrIsNull(value: unknown): int32 from "msHcrWinIsNull";
extern function hcrCallHandover(raw: unknown, state: unknown): unknown from "msHcrWinCallHandover";
extern function hcrCallInit(raw: unknown): void from "msHcrWinCallInit";
extern function hcrCallProbe(raw: unknown): int32 from "msHcrWinCallProbe";
extern function hcrNull(): unknown from "msHcrWinNull";
extern function hcrFixtureCore(): unknown from "hcrFixtureCore";
extern function hcrFixtureCallName(raw: unknown, name: cstring): void from "hcrFixtureCallName";
extern function hcrFixtureCallNameInt(raw: unknown, name: cstring): int32 from "hcrFixtureCallNameInt";
extern function hcrFixtureImportMatches(imports: unknown, moduleId: cstring, key: unknown): int32 from "hcrFixtureImportMatches";

function required(handle: unknown, name: string): unknown {
	const raw = hcrSymbol(handle, name);
	if (hcrIsNull(raw) != 0) {
		console.log("HCR-HOST missing symbol " + name);
		exit(1);
	}
	return raw;
}

function open(path: string): unknown {
	const image = hcrOpen(path);
	if (hcrIsNull(image) != 0) {
		console.log("HCR-HOST cannot load " + path);
		exit(1);
	}
	return image;
}

function handover(image: unknown, state: unknown): unknown {
	const raw = hcrSymbol(image, "_hcr_handover");
	if (hcrIsNull(raw) != 0) return hcrNull();
	return hcrCallHandover(raw, state);
}

function probe(entry: unknown, generation: string): void {
	const symbols = ["hcrIndirectValue", "hcrShapeValue", "hcrErrorValue", "hcrTickValue"];
	for (const symbol of symbols) {
		const value = hcrCallProbe(required(entry, symbol));
		console.log("HCR-HOST " + generation + " " + symbol + " -> " + value.toString());
	}
}

function imageName(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash >= 0 ? path.substring(slash + 1, path.length) : path;
}

function imageModuleId(name: string): string {
	return name == "module.dll" ? "app" : name.substring("module.".length, name.length - ".dll".length);
}

const images: unknown[] = [];
const names: string[] = [];
const states: unknown[] = [];
const reloads: string[] = [];
let inReloads = false;
for (let i = 1; i < argv.length; i += 1) {
	if (argv[i] == "--") {
		inReloads = true;
	} else if (inReloads) {
		reloads.push(argv[i]);
	} else {
		images.push(open(argv[i]));
		names.push(imageName(argv[i]));
	}
}
if (images.length == 0) {
	console.log("usage: host <image in dependency order>... [-- <reload image>...]");
	exit(2);
}
for (const image of images) states.push(handover(image, hcrNull()));
for (const image of images) hcrCallInit(required(image, "DatInit000"));
for (const image of images) hcrCallInit(required(image, "Init000"));
const entry = images[images.length - 1];
probe(entry, "gen1");

const core = hcrFixtureCore();
if (hcrIsNull(core) != 0) {
	console.log("HCR-HOST the core image is not loaded");
	exit(1);
}

function keysMatch(candidate: unknown, moduleId: string): boolean {
	const key = required(candidate, "HcrAbiKey000");
	let matches = true;
	for (let i = 0; i < images.length; i += 1) {
		const found = hcrFixtureImportMatches(required(images[i], "HcrImports000"), moduleId, key);
		if (found < 0) continue;
		console.log("HCR-HOST key " + names[i] + " -> " + moduleId + (found == 1 ? " matches" : " differs"));
		if (found == 0) matches = false;
	}
	return matches;
}

for (const path of reloads) {
	const slot = names.indexOf(imageName(path));
	if (slot < 0) {
		console.log("HCR-HOST no current image for " + path);
		exit(1);
	}
	const moduleId = imageModuleId(imageName(path));
	const candidate = open(path);
	if (!keysMatch(candidate, moduleId)) {
		console.log("HCR-HOST rejected " + path);
		continue;
	}
	hcrCallInit(required(core, "msHcrStageBegin"));
	const state = handover(candidate, states[slot]);
	if (hcrIsNull(state) != 0 && hcrIsNull(states[slot]) == 0) {
		console.log("HCR-HOST rejected " + path);
		exit(1);
	}
	hcrCallInit(required(candidate, "DatInit000"));
	hcrCallInit(required(core, "msHcrStageEnd"));
	const staged = hcrFixtureCallNameInt(required(core, "msHcrStaged"), moduleId);
	console.log("HCR-HOST staged " + moduleId + " -> " + staged.toString());
	console.log("HCR-HOST staged hcrIndirectValue -> " + hcrCallProbe(required(entry, "hcrIndirectValue")).toString());
	hcrFixtureCallName(required(core, "msHcrCommit"), moduleId);
	const previous = images[slot];
	images[slot] = candidate;
	states[slot] = state;
	console.log("HCR-HOST reloaded " + path);
	probe(entry, "gen2");
	hcrFixtureCallName(required(core, "msHcrRollback"), moduleId);
	images[slot] = previous;
	console.log("HCR-HOST rolled back " + moduleId);
	console.log("HCR-HOST rollback hcrIndirectValue -> " + hcrCallProbe(required(entry, "hcrIndirectValue")).toString());
}
