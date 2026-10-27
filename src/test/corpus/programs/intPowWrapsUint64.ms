// @stdout: kept 12157665459056928801
// @stdout: wrapped 18026252303461234787 0 18446744073709551615
// @stdout: assigned 6048575297968530377
// note: a uint64 power past the type's bound wraps like uint64 `*`, on every backend and under --danger.

function pow(a: uint64, b: uint64): uint64 { return a ** b; }

console.log(`kept ${pow(3, 40)}`);
console.log(`wrapped ${pow(3, 41)} ${pow(2, 64)} ${pow(18446744073709551615, 3)}`);
let n: uint64 = 3;
n **= 50 as uint64;
console.log(`assigned ${n}`);
