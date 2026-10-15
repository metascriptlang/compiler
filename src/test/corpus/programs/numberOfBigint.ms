// @stdout: 123 18446744073709552000 -9007199254740992 9007199254740996
// @xfail(raiser): cannot compile node kind BigIntLiteral at comptime (inbox 2026-10-09-raiser-bigint-literal-at-comptime-in-1117)
// note: Number() of a bigint rounds to the nearest float64, ties to even, as TS does.

const small: bigint = 123n;
const twoTo64: bigint = 18446744073709551616n;
const belowTie: bigint = -9007199254740993n;
const aboveTie: bigint = 9007199254740995n;
console.log(`${Number(small)} ${Number(twoTo64)} ${Number(belowTie)} ${Number(aboveTie)}`);
