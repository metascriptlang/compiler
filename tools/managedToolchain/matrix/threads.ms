function work(seed: int32): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < 200000; i = i + 1) { total = (total + i % 1000 * seed) % 1000003; }
	return total;
}

const first = spawn(() => work(3));
const second = spawn(() => work(5));
const third = spawn(() => work(7));
console.log("matrix-threads", await first, await second, await third);
