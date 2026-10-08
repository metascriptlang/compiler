// @exit: 1
// @stdout: before 2 5 3
// @xfail(danger): --danger drops the range check, as it drops every conversion check
// @xfail(raiser): fatal VM errors use a different stderr report from C and JS
// note: an integer converted to an enum outside the enum's ordinal bounds stops on every backend; the Raiser used to keep 9.

enum Color { Red, Green, Blue }

enum Sparse { One = 1, Five = 5 }

function raw(n: int32): int32 { return n; }

function small(n: int32): uint8 { return n as uint8; }

const c = raw(2) as Color;
const s = small(5) as Sparse;
const gap = raw(3) as Sparse;
console.log(`before ${c as int32} ${s as int32} ${gap as int32}`);
const bad = raw(9) as Color;
console.log(`after ${bad as int32}`);
