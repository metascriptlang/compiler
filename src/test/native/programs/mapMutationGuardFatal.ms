import { Map } from "std/core/struct";

function main(): void {
	const m = new Map<int32, int32>();
	m.set(1 as int32, 10 as int32);
	console.log("map-guard-fatal armed");
	m.writing = true;
	const v = m.get(1 as int32);
	console.log(`SHOULD-NOT-REACH ${v}`);
}
main();
