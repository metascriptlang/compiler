// @stdout: 2 0 5 true 3 2 0 5 false 2 4
enum Kind { Block, Other }
const top = Kind.Other;
const sum = top + 1;
const diff = top - 1;
const bits = top | 4;
const less = top < 3;
const lead = 2 + top;
function local(): string {
	const c = Kind.Other;
	const s = c + 1;
	const d = c - 1;
	const b = c | 4;
	const l = c > 3;
	return `${s} ${d} ${b} ${l}`;
}
let moving = Kind.Other;
const viaLet = moving + 1;
const viaMember = Kind.Other + 3;
console.log(`${sum} ${diff} ${bits} ${less} ${lead} ${local()} ${viaLet} ${viaMember}`);
