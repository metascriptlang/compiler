// note: a char converts to and from int64 and uint64 with `as`, takes part in their arithmetic after `as`, and compares with them, the same on C, JS and the Raiser; JS used to throw "Cannot mix BigInt and other types".

function wide(v: int64): int64 { return v; }
function wideU(v: uint64): uint64 { return v; }
function byte(v: int32): char { return v as char; }

const c = byte(200);
console.log(`to char ${(wide(65) as char) as int32} ${(wideU(250) as char) as int32}`);
const s: int64 = c as int64;
const u: uint64 = c as uint64;
console.log(`from char ${c as int64} ${c as uint64} ${s} ${u}`);
let acc: int64 = -5;
acc += c as int64;
console.log(`mixed ${wide(1) + (c as int64)} ${wideU(1) + (c as uint64)} ${acc} ${wide(200) == c} ${c < wideU(300)}`);
