// @stdout: 1|1|1.5|1.5|2|10|2.5|-1|b2d05e00|2|s
// @exit: 0
// note: a number-literal receiver (single, fractional, set, negative, past int32, beside a string) is its base for the extension overloads of toString — in a template, as a method call and with a radix; one numeric overload wins instead of every overload tying.

function pick(k: int32): 1 | 2 | string { return k > 0 ? 2 : "s"; }

const one: 1 = 1;
const half: 1.5 = 1.5;
const set: 1 | 2 = 2;
const mixed: 1 | 2.5 = 2.5;
const neg: -1 | 1 = -1;
const big: 3000000000 = 3000000000;

console.log([
	one.toString(),
	`${one}`,
	half.toString(),
	`${half}`,
	`${set}`,
	set.toString(2),
	`${mixed}`,
	`${neg}`,
	big.toString(16),
	`${pick(1)}`,
	`${pick(0)}`,
].join("|"));
