// @stdout: 1|1|1.5|1.5|2|2.5|-1|2|s
// @exit: 0
// note: a number-literal receiver (single, fractional, set, negative, beside a string) is its base for the extension overloads of toString — in a template and as a method call; one numeric overload wins instead of every overload tying.

function pick(k: int32): 1 | 2 | string { return k > 0 ? 2 : "s"; }

const one: 1 = 1;
const half: 1.5 = 1.5;
const set: 1 | 2 = 2;
const mixed: 1 | 2.5 = 2.5;
const neg: -1 | 1 = -1;

console.log([
	one.toString(),
	`${one}`,
	half.toString(),
	`${half}`,
	`${set}`,
	`${mixed}`,
	`${neg}`,
	`${pick(1)}`,
	`${pick(0)}`,
].join("|"));
