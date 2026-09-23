import { argv, exit } from "std/process";

@include("runtime/hcr.h");

extern function hcrOpen(path: cstring): unknown from "msHcrWinOpen";
extern function hcrSymbol(handle: unknown, name: cstring): unknown from "msHcrWinSymbol";
extern function hcrIsNull(value: unknown): int32 from "msHcrWinIsNull";
extern function hcrCallHandover(raw: unknown, state: unknown): unknown from "msHcrWinCallHandover";
extern function hcrCallInit(raw: unknown): void from "msHcrWinCallInit";
extern function hcrCallProbe(raw: unknown): int32 from "msHcrWinCallProbe";
extern function hcrNull(): unknown from "msHcrWinNull";

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

for (const path of reloads) {
	const slot = names.indexOf(imageName(path));
	if (slot < 0) {
		console.log("HCR-HOST no current image for " + path);
		exit(1);
	}
	const candidate = open(path);
	const state = handover(candidate, states[slot]);
	if (hcrIsNull(state) != 0 && hcrIsNull(states[slot]) == 0) {
		console.log("HCR-HOST rejected " + path);
		exit(1);
	}
	hcrCallInit(required(candidate, "DatInit000"));
	images[slot] = candidate;
	states[slot] = state;
	console.log("HCR-HOST reloaded " + path);
}
if (reloads.length > 0) probe(entry, "gen2");
