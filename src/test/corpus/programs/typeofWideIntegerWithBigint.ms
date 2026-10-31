// @skip-raiser: bigint has no Raiser VM representation
// @stdout: number bigint object|number bigint|number bigint object|number bigint|number bigint int big
function pick(i: int32): int64 | bigint | null {
	if (i == 0) return 5 as int64;
	if (i == 1) return 7n;
	return null;
}
function pick2(i: int32): int64 | bigint {
	if (i == 0) return 5 as int64;
	return 7n;
}
function pickU(i: int32): uint64 | bigint | null {
	if (i == 0) return 5 as uint64;
	if (i == 1) return 7n;
	return null;
}
function pickU2(i: int32): uint64 | bigint {
	if (i == 0) return 5 as uint64;
	return 7n;
}
function pick32(i: int32): int32 | bigint {
	if (i == 0) return 5;
	return 7n;
}
function narrowed(v: int64 | bigint): string {
	if (typeof v === "bigint") return "big";
	return "int";
}
const a: string[] = [];
for (let i = 0; i < 3; i++) a.push(typeof pick(i));
const b: string[] = [];
for (let i = 0; i < 2; i++) b.push(typeof pick2(i));
const c: string[] = [];
for (let i = 0; i < 3; i++) c.push(typeof pickU(i));
const d: string[] = [];
for (let i = 0; i < 2; i++) d.push(typeof pickU2(i));
const e: string[] = [];
for (let i = 0; i < 2; i++) e.push(typeof pick32(i));
console.log([a.join(" "), b.join(" "), c.join(" "), d.join(" "), e.join(" ")].join("|"), narrowed(5 as int64), narrowed(6n));
