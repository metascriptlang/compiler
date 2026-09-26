import { copyFile, readFile, writeFile } from "std/fs";
import { exit, platform } from "std/process";
import { reload, reloadKindName } from "std/hcr";
import { tick, value } from "./logic";
import { Probe, makeProbe, version } from "./lifecycle";

const EXT = platform == "windows" ? ".dll" : platform == "darwin" ? ".dylib" : ".so";
const BUNDLE = `module${EXT}.hcrabi`;

function image(moduleId: string): string {
	return `module.${moduleId}${EXT}`;
}

function place(generation: string, name: string): void {
	if (!copyFile(`${generation}/${name}`, `run/${name}`).ok) {
		console.log(`HCR-ENGINE cannot place ${generation}/${name}`);
		exit(1);
	}
}

function truncate(generation: string, name: string): void {
	const bytes = readFile(`${generation}/${name}`);
	if (!bytes.ok || !writeFile(`run/${name}`, bytes.value.byteSlice(0, 512)).ok) {
		console.log(`HCR-ENGINE cannot truncate ${name}`);
		exit(1);
	}
}

function report(label: string): void {
	const outcome = reload();
	const names = outcome.modules.length > 0 ? " " + outcome.modules.join(",") : "";
	const reason = outcome.reason != "" ? ` (${outcome.reason})` : "";
	console.log(`HCR-ENGINE ${label}: ${reloadKindName(outcome.kind)}${names}${reason}`);
}

function inspect(label: string): void {
	const held = probe!;
	const fresh = makeProbe(8);
	console.log(`HCR-ENGINE ${label}: instanceof ${held instanceof Probe} ${fresh instanceof Probe} scaled ${held.scaled()}`);
}

function show(label: string): void {
	console.log(`HCR-ENGINE ${label}: value ${value()} tick ${tick()} version ${version()}`);
}

let probe: Probe | null = makeProbe(7);
show("start");
report("unchanged");

place("g2", image("logic"));
place("g2", BUNDLE);
report("body edit");
show("after body edit");

truncate("g1", image("logic"));
place("g1", BUNDLE);
report("truncated image");
report("same truncated image");
place("g1", image("logic"));
report("complete image");
show("after complete image");

place("g2", image("lifecycle"));
place("g2", BUNDLE);
report("lifecycle rebuilt");
inspect("probe from the first generation");

place("g5", image("lifecycle"));
place("g5", BUNDLE);
report("after-reload handler throws");
show("after rollback");
inspect("probe after rollback");
probe = null;

place("g3", image("logic"));
place("g3", BUNDLE);
report("added export, app not rebuilt");
show("after rejection");

place("g4", image("logic"));
place("g4", BUNDLE);
report("state layout changed");
show("after layout rejection");

place("g1", image("logic"));
place("g6", image("lifecycle"));
place("g6", BUNDLE);
report("class layout changed");
show("after class layout rejection");

place("g2", image("core"));
place("g2", BUNDLE);
report("core changed");
