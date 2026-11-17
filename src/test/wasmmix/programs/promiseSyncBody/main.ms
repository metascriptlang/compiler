// @stdout: 6 6
// @stdout: 8
import { total, bump } from "./promiseSyncBodyWasm";

async function run(): Promise<void> {
	let xs: Vec<int32> = [1, 2, 3];
	console.log(`${await total(xs)} ${xs[0]}`);
	let n = 7;
	await bump(n);
	console.log(`${n}`);
}
run();
