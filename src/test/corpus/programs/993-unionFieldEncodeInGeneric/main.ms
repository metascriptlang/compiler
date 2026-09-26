// @stdout: {"log":{"name":"o","ev":{"kind":"Click","x":7}},"n":1}
import { Log } from "./log";
import { EvKind } from "./ev";

interface Outer { log: Log; n: int32; }

function run(): void {
	const l: Log = { name: "h", ev: { kind: EvKind.Key, code: 42 } };
	const o: Outer = { log: { name: "o", ev: { kind: EvKind.Click, x: 7 } }, n: 1 };
	console.log(JSON.stringify(l));
	console.log(JSON.stringify(o));
}

run();
