// @slots
// @stdout: 82500
// @stdout: 80
// @stdout: 6
// @stdout: 6
// @stdout: 3,3
// @stdout: 14.5
import { tick, ping, both } from "./callbackSlotsWasm";

function nest(n: int32): int32 {
	if (n == 0) return 0;
	return tick((): int32 => nest(n - 1) + 1);
}

let total = 0;
for (let i = 0; i < 33000; i += 1) {
	total = total + tick((): int32 => i & 3);
}
console.log(`${total}`);
console.log(`${nest(40)}`);
console.log(`${nest(3)}`);
console.log(`${tick((): int32 => 5)}`);

const hits: int32[] = [];
const fired = ping((): void => { hits.push(1); });
console.log(`${fired},${hits.length}`);

console.log(`${both((x: int32): int32 => x * 2, (x: float64): float64 => x + 0.5)}`);
