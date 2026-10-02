import { reloadKindName } from "std/hcr";
import { change } from "./support";
import { localHandler, makeAdder, snapshot, tick, version } from "./logic";

const table = { pick: version };
let rebound: () => int32 = version;

@afterReload
function rebind(): void {
	rebound = version;
}

function load(generation: string): void {
	const result = change(generation, ["logic"]);
	console.log(`HCR-FN ${generation}: ${reloadKindName(result.kind)} ${result.modules.join(",")} [${result.reason}]`);
}

function run(): void {
	const heldVersion: () => int32 = version;
	const heldTick: () => int32 = tick;
	const heldLocal: () => int32 = localHandler();
	const heldAdder: (x: int32) => int32 = makeAdder(100);
	console.log(`HCR-FN g1: direct ${version()} held ${heldVersion()} table ${table.pick()} rebound ${rebound()} local ${heldLocal()} adder ${heldAdder(1)}`);
	load("g2");
	const freshVersion: () => int32 = version;
	const freshLocal: () => int32 = localHandler();
	const freshAdder: (x: int32) => int32 = makeAdder(100);
	console.log(`HCR-FN after g2: direct ${version()} held ${heldVersion()} fresh ${freshVersion()} table ${table.pick()} rebound ${rebound()} local ${heldLocal()} fresh-local ${freshLocal()} adder ${heldAdder(1)} fresh-adder ${freshAdder(1)}`);
	const t1 = heldTick();
	const t2 = tick();
	console.log(`HCR-FN state before reset: held-tick ${t1} direct-tick ${t2} snapshot ${snapshot()}`);
	load("g3");
	const t3 = heldTick();
	const t4 = tick();
	const t5 = heldTick();
	console.log(`HCR-FN after g3 reset: held-tick ${t3} direct-tick ${t4} held-tick ${t5} snapshot ${snapshot()} held-version ${heldVersion()} rebound ${rebound()}`);
}

run();
