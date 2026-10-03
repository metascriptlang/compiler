import { argv, exit } from "std/process";

@include("runtime/hcr.h");
@include("./hostCalls.h");

extern function hcrOpen(path: cstring): Ptr<void> from "msHcrImageOpen";
extern function hcrSymbol(handle: Ptr<void>, name: cstring): Ptr<void> from "msHcrImageSymbol";
extern function hcrIsNull(value: Ptr<void>): int32 from "msHcrImageIsNull";
extern function hcrCallInit(raw: Ptr<void>): void from "msHcrImageCallInit";
extern function hcrCallProbe(raw: Ptr<void>): int32 from "msHcrImageCallProbe";
extern function hcrFixtureCore(): Ptr<void> from "hcrFixtureCore";
extern function hcrImageExt(): string from "hcrFixtureImageExt";
extern function hcrFixtureCallName(raw: Ptr<void>, name: cstring): void from "hcrFixtureCallName";
extern function hcrFixtureCallNameInt(raw: Ptr<void>, name: cstring): int32 from "hcrFixtureCallNameInt";
extern function hcrFixtureBindingsMatch(bindings: Ptr<void>, moduleId: cstring, functions: Ptr<void>, variables: Ptr<void>): int32 from "hcrFixtureBindingsMatch";

function required(handle: Ptr<void>, name: string): Ptr<void> {
	const raw = hcrSymbol(handle, name);
	if (hcrIsNull(raw) != 0) {
		console.log("HCR-HOST missing symbol " + name);
		exit(1);
	}
	return raw;
}

function open(path: string): Ptr<void> {
	const image = hcrOpen(path);
	if (hcrIsNull(image) != 0) {
		console.log("HCR-HOST cannot load " + path);
		exit(1);
	}
	return image;
}

function probe(entry: Ptr<void>, generation: string): void {
	for (const symbol of ["hcrIndirectValue", "hcrShapeValue", "hcrErrorValue", "hcrTickValue"]) {
		const value = hcrCallProbe(required(entry, symbol));
		console.log("HCR-HOST " + generation + " " + symbol + " -> " + value.toString());
	}
}

function imageName(path: string): string {
	const slash = path.lastIndexOf("/");
	return slash >= 0 ? path.substring(slash + 1, path.length) : path;
}

function imageModuleId(name: string): string {
	const ext = hcrImageExt();
	return name == `module${ext}` ? "app" : name.substring("module.".length, name.length - ext.length);
}

const images: Ptr<void>[] = [];
const names: string[] = [];
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
for (const image of images) hcrCallInit(required(image, "DatInit000"));
for (const image of images) hcrCallInit(required(image, "Init000"));
const entry = images[images.length - 1];
probe(entry, "gen1");
const core = hcrFixtureCore();
if (hcrIsNull(core) != 0) {
	console.log("HCR-HOST the core image is not loaded");
	exit(1);
}

function bindingsMatch(candidate: Ptr<void>, moduleId: string): boolean {
	let matches = true;
	for (let i = 0; i < images.length; i += 1) {
		const found = hcrFixtureBindingsMatch(required(images[i], "HcrBindings000"), moduleId,
			required(candidate, "HcrFunctions000"), required(candidate, "HcrVariables000"));
		if (found < 0) continue;
		console.log("HCR-HOST bindings " + names[i] + " -> " + moduleId + (found == 1 ? " match" : " differ"));
		if (found == 0) matches = false;
	}
	return matches;
}

for (let index = 0; index < reloads.length; index += 1) {
	const path = reloads[index];
	const slot = names.indexOf(imageName(path));
	if (slot < 0) {
		console.log("HCR-HOST no current image for " + path);
		exit(1);
	}
	const moduleId = imageModuleId(imageName(path));
	const candidate = open(path);
	if (!bindingsMatch(candidate, moduleId)) {
		console.log("HCR-HOST rejected " + path);
		console.log("HCR-HOST rejection hcrIndirectValue -> " + hcrCallProbe(required(entry, "hcrIndirectValue")).toString());
		console.log("HCR-HOST rejection hcrTickValue -> " + hcrCallProbe(required(entry, "hcrTickValue")).toString());
		continue;
	}
	hcrCallInit(required(core, "msHcrStageBegin"));
	hcrCallInit(required(candidate, "DatInit000"));
	hcrCallInit(required(core, "msHcrStageEnd"));
	console.log("HCR-HOST staged " + moduleId + " -> " + hcrFixtureCallNameInt(required(core, "msHcrStaged"), moduleId).toString());
	console.log("HCR-HOST staged hcrIndirectValue -> " + hcrCallProbe(required(entry, "hcrIndirectValue")).toString());
	hcrFixtureCallName(required(core, "msHcrCommit"), moduleId);
	hcrCallInit(required(candidate, "Init000"));
	console.log("HCR-HOST reloaded " + path);
	probe(entry, "gen2");
	if (index == 0) {
		hcrFixtureCallName(required(core, "msHcrRollback"), moduleId);
		console.log("HCR-HOST rolled back " + moduleId);
		console.log("HCR-HOST rollback hcrIndirectValue -> " + hcrCallProbe(required(entry, "hcrIndirectValue")).toString());
		console.log("HCR-HOST rollback hcrTickValue -> " + hcrCallProbe(required(entry, "hcrTickValue")).toString());
	} else {
		hcrFixtureCallName(required(core, "msHcrFinalize"), moduleId);
		images[slot] = candidate;
		console.log("HCR-HOST finalized " + moduleId);
	}
}
