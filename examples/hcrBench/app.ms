import { exit } from "std/process";
import { reload } from "std/hcr";
import { inc } from "./target";

function local(x: int64): int64 {
	return x + 1;
}

const N: int64 = 50000000;

function sameModule(): float64 {
	const n = N;
	let acc: int64 = 0;
	const t0 = performance.now();
	for (let i: int64 = 0; i < n; i += 1) acc = local(acc);
	const spent = performance.now() - t0;
	if (acc != n) console.log("BENCH wrong");
	return spent * 1000000 / (n as float64);
}

function crossModule(): float64 {
	const n = N;
	let acc: int64 = 0;
	const t0 = performance.now();
	for (let i: int64 = 0; i < n; i += 1) acc = inc(acc);
	const spent = performance.now() - t0;
	if (acc != n) console.log("BENCH wrong");
	return spent * 1000000 / (n as float64);
}

function viaValue(): float64 {
	const f: (x: int64) => int64 = inc;
	const n = N;
	let acc: int64 = 0;
	const t0 = performance.now();
	for (let i: int64 = 0; i < n; i += 1) acc = f(acc);
	const spent = performance.now() - t0;
	if (acc != n) console.log("BENCH wrong");
	return spent * 1000000 / (n as float64);
}

const kind = reload();
for (let round = 0; round < 3; round += 1) {
	console.log(`BENCH same ${sameModule()} cross ${crossModule()} value ${viaValue()} ns/call (reload ${kind})`);
}
exit(0);
