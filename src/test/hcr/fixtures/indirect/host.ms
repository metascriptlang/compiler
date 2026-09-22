import { argv, exit } from "std/process";

@include("runtime/hcr.h");

extern function hcrOpen(path: cstring): unknown from "msHcrWinOpen";
extern function hcrSymbol(handle: unknown, name: cstring): unknown from "msHcrWinSymbol";
extern function hcrIsNull(value: unknown): int32 from "msHcrWinIsNull";
extern function hcrCallInit(raw: unknown): void from "msHcrWinCallInit";
extern function hcrCallProbe(raw: unknown): int32 from "msHcrWinCallProbe";

function required(handle: unknown, name: string): unknown {
	const raw = hcrSymbol(handle, name);
	if (hcrIsNull(raw) != 0) {
		console.log("HCR-HOST missing symbol " + name);
		exit(1);
	}
	return raw;
}

if (argv.length < 2) {
	console.log("usage: host <image>");
	exit(2);
}
const image = hcrOpen(argv[1]);
if (hcrIsNull(image) != 0) {
	console.log("HCR-HOST cannot load " + argv[1]);
	exit(1);
}
hcrCallInit(required(image, "DatInit000"));
hcrCallInit(required(image, "Init000"));
console.log("HCR-HOST call -> " + hcrCallProbe(required(image, "hcrIndirectValue")).toString());
