// @stdout: float32-const-ok
// note: a float32 const takes part in an expression with the value its global holds, folded or not; each backend's own float32 arithmetic is the reference.

import { exit } from "std/process";

const STEP: float32 = 0.42;
const CHANCE: float32 = 0.7;
const RADIUS: float32 = 22.0;
const BIG: float32 = 16777217.0;
const ONE: float32 = 1.0;
const SUM: float32 = BIG + ONE;
const WIDE: float64 = STEP;

class Knobs {
	static readonly SPACING: float32 = 0.42;
	static readonly WIDE: float64 = STEP;
}

let stepRt: float32 = 0.42;
let chanceRt: float32 = 0.7;
let radiusRt: float32 = 22.0;
let bigRt: float32 = 16777217.0;
let oneRt: float32 = 1.0;

function times(a: float32, b: float32): float32 {
	return a * b;
}

function main(): void {
	const wideRt: float64 = stepRt;
	for (let n = 0; n < 1000; n++) {
		const x = n as float32;
		const r: float32 = x / 1000.0;
		if (x * STEP != times(x, stepRt)) exit(1);
		if ((r - 0.5) * STEP != (r - 0.5) * stepRt) exit(2);
		if ((r < CHANCE) != (r < chanceRt)) exit(3);
		if (x * -STEP != x * -stepRt) exit(4);
		if (x * Knobs.SPACING != x * stepRt) exit(5);
		if (-RADIUS + x * STEP != -radiusRt + x * stepRt) exit(6);
	}
	const sumRt: float32 = bigRt + oneRt;
	if (BIG + ONE != sumRt || SUM != sumRt) exit(7);
	if (WIDE != wideRt || WIDE * 3.0 != wideRt * 3.0) exit(8);
	if (Knobs.WIDE != wideRt || Knobs.WIDE * 3.0 != wideRt * 3.0) exit(9);
	console.log("float32-const-ok");
}

main();
