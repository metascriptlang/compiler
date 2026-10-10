import { readFile, writeFile } from "std/fs";
import { reload, lastReload, reloadKindName, ReloadKind } from "std/hcr";
import { Box } from "./box";
import { peek } from "./peek";
import { give, probe } from "./logic";

function line(): string {
	const given = (give() as unknown) as Box<int32>;
	const wide: unknown = new Box<float64>(1.5);
	return probe() + " given " + given.v.toString() + " peek " + peek((wide as unknown) as Box<float64>);
}

console.log("IDENT " + line());
console.log("IDENT " + line());
for (const version of ["v2", "v3"]) {
	const source = readFile("logic.ms");
	if (!source.ok || !writeFile("logic.ms", source.value.replaceAll(version == "v2" ? " v1" : " v2", " " + version)).ok) throw new Error("cannot edit logic.ms");
	const deadline = performance.now() + 60000;
	let changed = false;
	while (!changed && performance.now() < deadline) {
		const kind = reload();
		if (kind == ReloadKind.Reloaded) {
			changed = true;
			console.log("IDENT " + line());
		} else if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) {
			throw new Error("reload failed: " + lastReload().reason);
		} else {
			await sleepAsync(20);
		}
	}
	if (!changed) throw new Error("reload timed out");
}
const boxSource = readFile("box.ms");
if (!boxSource.ok || !writeFile("box.ms", boxSource.value.replaceAll("\tv: T;", "\tv: T;\n\textra: int32 = 0;")).ok) throw new Error("cannot edit box.ms");
const layoutDeadline = performance.now() + 60000;
let verdict = "timed out";
while (verdict == "timed out" && performance.now() < layoutDeadline) {
	const kind = reload();
	if (kind != ReloadKind.NoChange && kind != ReloadKind.Pending) verdict = reloadKindName(kind) + ": " + lastReload().reason;
	else await sleepAsync(20);
}
console.log("IDENT layout " + verdict);
