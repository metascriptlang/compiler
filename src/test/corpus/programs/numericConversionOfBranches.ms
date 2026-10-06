// @stdout: 7 0 7 4294967295 5 0 4294967295 2 0 2 7
// note: `(m.get(k) ?? 0) as uint64` and `(c ? x : 0) as uint64` convert the value the branch selects, as converting the joined int32 would; the `as` target still types a literal arm (`0xFFFFFFFF` under `as int64` stays 4294967295). Before, the target was fitted into each arm as an implicit conversion and refused ("implicit int32 → uint64 conversion changes signedness"). The same expressions in a declared slot stay refused.
function fromMap(m: Map<int32, int32>, k: int32): uint64 { return (m.get(k) ?? 0) as uint64; }
function wideHex(m: Map<int32, int32>, k: int32): int64 { return (m.get(k) ?? 0xFFFFFFFF) as int64; }
function pick(c: boolean, x: int32): uint64 { return (c ? x : 0) as uint64; }
function hexArm(c: boolean): int64 { return (c ? 1 : 0xFFFFFFFF) as int64; }
function floored(c: boolean, f: float64): int32 { return (c ? f : 0) as int32; }
function narrow(c: boolean, w: int64): uint8 { return (c ? w : 7) as uint8; }
const m = new Map<int32, int32>();
m.set(3, 7);
console.log(`${fromMap(m, 3)} ${fromMap(m, 4)} ${wideHex(m, 3)} ${wideHex(m, 4)} ${pick(true, 5)} ${pick(false, 5)} ${hexArm(false)} ${floored(true, 2.75)} ${floored(false, 2.75)} ${narrow(true, 258)} ${narrow(false, 258)}`);
