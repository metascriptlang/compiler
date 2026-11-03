// randomInt(min, max) draws an integer in [min, max): a result of -1 is a value, not a failure, every value of the
// range turns up, and a bad bound is an error that names it (non-integer, NaN, infinite, empty range, range of 2^48 or more).
//
// @stdout: minus one 200 all true
// @stdout: -3..3 errors 0 seen 6 inRange true
// @stdout: 2^48-1 span ok true
// @stdout: bad 0.5: min must be a safe integer
// @stdout: bad NaN: min must be a safe integer
// @stdout: bad inf: max must be a safe integer
// @stdout: bad 2^53: max must be a safe integer
// @stdout: bad equal: max must be greater than min
// @stdout: bad reversed: max must be greater than min
// @stdout: bad 2^48: max - min must be less than 2^48
// @stdout: bad 2^48+1: max - min must be less than 2^48
// @exit: 0
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

@passC("-Werror=incompatible-pointer-types");

import { randomIntSync } from "std/crypto";

let minusOne = 0;
for (let i = 0; i < 200; i++) {
	const r = randomIntSync(-1, 0);
	if (r.ok && r.value == -1) minusOne++;
}
console.log(`minus one 200 all ${minusOne == 200}`);

const seen = new Set<number>();
let errors = 0;
let inRange = true;
for (let i = 0; i < 2000; i++) {
	const r = randomIntSync(-3, 3);
	if (!r.ok) {
		errors++;
		continue;
	}
	if (r.value < -3 || r.value >= 3) inRange = false;
	seen.add(r.value);
}
console.log(`-3..3 errors ${errors} seen ${seen.size} inRange ${inRange}`);

const wide = randomIntSync(0, 281474976710655);
console.log(`2^48-1 span ok ${wide.ok && wide.value >= 0 && wide.value < 281474976710655}`);

function bad(label: string, min: number, max: number): void {
	const r = randomIntSync(min, max);
	console.log(r.ok ? `bad ${label}: ok ${r.value}` : `bad ${label}: ${r.error.message}`);
}

bad("0.5", 0.5, 1.5);
bad("NaN", NaN, 1);
bad("inf", 0, Infinity);
bad("2^53", 0, 9007199254740992);
bad("equal", 5, 5);
bad("reversed", 5, 2);
bad("2^48", 0, 281474976710656);
bad("2^48+1", 0, 281474976710657);
