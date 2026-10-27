// @stdout: kept 3486784401
// @stdout: wrapped 1870418611 0 255 48967
// @stdout: assigned 1870418611
// note: a uint32 power past the type's bound wraps like uint32 `*`, on every backend and under --danger; uint8 and uint16 wrap at their own width.

function pow(a: uint32, b: uint32): uint32 { return a ** b; }
function pow8(a: uint8, b: uint8): uint8 { return a ** b; }
function pow16(a: uint16, b: uint16): uint16 { return a ** b; }

console.log(`kept ${pow(3, 20)}`);
console.log(`wrapped ${pow(3, 21)} ${pow(2, 32)} ${pow8(255, 5)} ${pow16(7, 9)}`);
let n: uint32 = 3;
n **= 21 as uint32;
console.log(`assigned ${n}`);
