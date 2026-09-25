import { argv, exit } from "std/process";

@include("./hostCalls.h");

extern function hcrOpen(path: cstring): unknown from "msHcrImageOpen";
extern function hcrSymbol(handle: unknown, name: cstring): unknown from "msHcrImageSymbol";
extern function hcrIsNull(value: unknown): int32 from "msHcrImageIsNull";
extern function hcrFailure(): string from "msHcrFailureText";
extern function hcrImageExt(): string from "msHcrImageExt";
extern function hcrCopyImage(from: cstring, to: cstring): int32 from "msHcrCopyImage";
extern function hcrMakeDir(path: cstring): int32 from "msHcrMakeDir";
extern function hcrProcessId(): uint32 from "msHcrProcessId";
extern function hcrLaunch(raw: unknown, dir: cstring, stem: cstring): void from "hcrFixtureLaunch";
extern function hcrStart(raw: unknown): int32 from "hcrFixtureStart";

function fail(message: string): void {
	console.log(`HCR-HOST ${message}`);
	exit(1);
}

function required(handle: unknown, name: string): unknown {
	const raw = hcrSymbol(handle, name);
	if (hcrIsNull(raw) != 0) fail(`the core image does not export ${name}`);
	return raw;
}

if (argv.length != 3) fail("usage: host <image dir> <stem>");
const dir = argv[1];
const stem = argv[2];
const coreDir = `${dir}/.hcr/${hcrProcessId()}/core`;
for (const path of [`${dir}/.hcr`, `${dir}/.hcr/${hcrProcessId()}`, coreDir]) {
	if (hcrMakeDir(path) == 0) fail(`cannot create ${path}`);
}
const coreName = `${stem}.core${hcrImageExt()}`;
const coreCopy = `${coreDir}/${coreName}`;
if (hcrCopyImage(`${dir}/${coreName}`, coreCopy) == 0) fail(`cannot copy the core image (${hcrFailure()})`);
const core = hcrOpen(coreCopy);
if (hcrIsNull(core) != 0) fail(`cannot load ${coreCopy} (${hcrFailure()})`);
hcrLaunch(required(core, "msHcrLaunch"), dir, stem);
exit(hcrStart(required(core, "msHcrEngineStart")));
