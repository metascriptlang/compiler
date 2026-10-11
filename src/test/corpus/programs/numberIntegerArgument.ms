// @stdout: 4 -4 5000000000 200 70000 4.5 7 1 -3
// note: Number() takes an integer of any kind: an integer literal picks one overload instead of tying between int64 and uint64, and a typed integer converts through its own kind.

const small: uint8 = 200;
const wide: uint32 = 70000;
const signed: int8 = -3;
console.log(`${Number(4)} ${Number(-4)} ${Number(5000000000)} ${Number(small)} ${Number(wide)} ${Number(4.5)} ${Number("7")} ${Number(true)} ${Number(signed)}`);
