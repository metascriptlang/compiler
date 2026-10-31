// @stdout: num 9007199254740992 9007199254740992 9007199254740994 9007199254740996 18014398509481984 18014398509481990 18014398509481988 -9007199254740992 -9007199254740996 8.98846567431158e+307 Infinity Infinity 1.7976931348623157e+308 1.7976931348623157e+308 -Infinity Infinity 0 1 -1 18446744073709552000 1.2676506002282297e+30
// @xfail(raiser): bigint is not supported on the Raiser VM
// note: Number() of a bigint rounds half to even at the 2^53 boundary and overflows to Infinity at or past the midpoint between the largest float64 and 2^1024, as TS does.

function p(n: bigint): bigint { return 1n << n; }

const values: bigint[] = [
	p(53n), p(53n) + 1n, p(53n) + 2n, p(53n) + 3n, p(54n) + 2n, p(54n) + 6n, p(54n) + 3n,
	-(p(53n) + 1n), -(p(53n) + 3n), p(1023n), p(1024n) - 1n, p(1024n) - p(970n), p(1024n) - p(970n) - 1n,
	p(1024n) - p(971n), -p(1024n), p(4000n), 0n, 1n, -1n, p(64n) - 1n, p(100n) + p(47n) + 1n,
];
let line = "num";
for (const v of values) line += ` ${Number(v)}`;
console.log(line);
