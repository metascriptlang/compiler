// Parity program — `new Date(ms)` keeps its millisecond count (truncated toward zero, negative zero
// becomes zero, NaN past +-8.64e15), `getTime()` and `valueOf()` read it, and `<` `<=` `>` `>=`
// order two dates by it through `valueOf`, never by address (the later date is allocated first).
// `Date.now()` and `new Date()` are positive; the wall clock itself is never printed. A `Date` is a
// declared type: it crosses a function boundary and its `getTime()` prints as a number.
//
// @stdout: time 1000 2000|order true false true false|equal true true false|valueOf 1000 1005|truncates 1000 -1000 0|range 8640000000000000 true|clip Infinity Infinity Infinity -8640000000000000 8639999999999999 true true true true true true|now true true true true
// @exit: 0
// @xfail(raiser): the Raiser has no Date (inbox 2026-10-16-raiser-has-no-date)

function earlier(a: Date, b: Date): Date { return a < b ? a : b; }
function whole(ms: number): boolean { return ms == Math.trunc(ms); }
function zeroSign(ms: number): number { return 1 / new Date(ms).getTime(); }
function clipped(ms: number): boolean { const t = new Date(ms).getTime(); return t != t; }

const late = new Date(2000);
const early = new Date(1000);
const beyond = new Date(8.64e15 + 1).getTime();

const rows: string[] = [
	`time ${early.getTime()} ${late.getTime()}`,
	`order ${late > early} ${early > late} ${early < late} ${early >= late}`,
	`equal ${new Date(1000) <= new Date(1000)} ${new Date(1000) >= new Date(1000)} ${new Date(1000) < new Date(1000)}`,
	`valueOf ${late.valueOf() - early.valueOf()} ${early.valueOf() + 5}`,
	`truncates ${new Date(1000.9).getTime()} ${new Date(-1000.9).getTime()} ${new Date(-0.5).getTime()}`,
	`range ${new Date(8.64e15).getTime()} ${beyond != beyond}`,
	`clip ${zeroSign(-0)} ${zeroSign(-0.5)} ${zeroSign(-1e-300)} ${new Date(-8.64e15).getTime()} ${new Date(8.64e15 - 1).getTime()} ` +
		`${clipped(-8.64e15 - 1)} ${clipped(Number.POSITIVE_INFINITY)} ${clipped(Number.NEGATIVE_INFINITY)} ${clipped(Number.NaN)} ${clipped(Number.MAX_VALUE)} ${clipped(-Number.MAX_VALUE)}`,
	`now ${Date.now() > 0} ${new Date().getTime() > 0} ${whole(Date.now())} ${whole(new Date().getTime())}`,
];
console.log(rows.join("|"));
console.log(earlier(late, early).getTime());
