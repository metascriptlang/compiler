// @stdout: worker-exit sibling armed 45
// @exit: 3
// @serial
// @skip-raiser

function spin(n: int32): int32 {
	let sum: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) sum = (sum + i) % 1000;
	return sum;
}

function quit(): int32 {
	process.exit(3);
	return 0;
}

console.log(`worker-exit sibling armed ${await spawn(() => spin(10))}`);
const busy = spawn(() => spin(100000000));
const killer = spawn(() => quit());
const local = spin(5000000);
console.log(`SHOULD-NOT-REACH ${await busy + await killer + local}`);
