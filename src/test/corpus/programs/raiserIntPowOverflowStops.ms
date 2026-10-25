// @exit: 1
// @stdout: kept 4052555153018976267 -9223372036854775808
// @stdout: 1162261467
// @stdout: over- or underflow
// note: an integer `**` whose power leaves its type stops with the overflow defect on every backend, an int64 at 2^63;
// the lines before it print.

function i64(n: int64): int64 { return n; }
function i32(n: int32): int32 { return n; }

console.log(`kept ${i64(3) ** i64(39)} ${i64(-2) ** i64(63)}`);
console.log(`${i32(3) ** i32(19)}`);
console.log(`${i64(2) ** i64(63)}`);
console.log("unreachable");
