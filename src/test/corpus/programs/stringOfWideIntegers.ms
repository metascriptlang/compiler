// @stdout: 1844674407370955161 18446744073709551615 -9223372036854775808 9223372036854775807 | 1844674407370955161 18446744073709551615 -9223372036854775808 9223372036854775807 | A 19
// note: String() of a uint64 or int64 past 2^53 prints its exact digits, as a template and console.log do, and String() of a char prints the character. Same output on C, JS and the Raiser.
const MAX: uint64 = 18446744073709551615;
const q: uint64 = MAX / 10;
const lo: int64 = -9223372036854775807 - 1;
const hi: int64 = 9223372036854775807;
const c: char = "A".code;
console.log(`${String(q)} ${String(MAX)} ${String(lo)} ${String(hi)} | ${q} ${MAX} ${lo} ${hi} | ${String(c)} ${String(q).length}`);
