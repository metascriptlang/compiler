// @stdout: start
// @stdout: after run
// @stdout: doubled 42
// @stdout: ready 2
// @stdout: hello wasm
// @stdout: label n=3 3
// @stdout: maybe 5 null
// @stdout: series 3 1
// @stdout: caught bad 1
// @stdout: failing ok 0
// @stdout: nothing ran 7
// @stdout: reported 4
// @stdout: reporting 104
// @stdout: all 2 4
// @stdout: done
import { doubled, ready, greeting, labelled, maybe, series, failing, nothing, reporting } from "./asyncResultsWasm";

async function run(): Promise<void> {
	console.log(`doubled ${await doubled(21)}`);
	console.log(`ready ${await ready(1)}`);
	console.log(await greeting("wasm"));
	const l = await labelled(3);
	console.log(`label ${l.text} ${l.count}`);
	console.log(`maybe ${await maybe(5)} ${await maybe(0)}`);
	const s = await series(3);
	console.log(`series ${s.length} ${s[2]}`);
	try {
		await failing(1);
	} catch (e) {
		console.log(`caught ${e.message}`);
	}
	console.log(`failing ok ${await failing(0)}`);
	await nothing(7);
	console.log(`reporting ${await reporting(4, (v) => { console.log(`reported ${v}`); })}`);
	const both = await Promise.all([doubled(1), doubled(2)]);
	console.log(`all ${both[0]} ${both[1]}`);
}

console.log("start");
run().then(() => { console.log("done"); });
console.log("after run");
