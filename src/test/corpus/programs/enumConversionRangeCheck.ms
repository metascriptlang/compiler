// @exit: 1
// @stdout: in=2 hole=3 member=1
// @skip-js: node exits 1 with the same "value … not in range" line but wraps it in its own uncaught-error report, and parity compares merged stdout+stderr (sibling of 650); the JS check is pinned in js/intConv.ms
// @xfail(danger): --danger drops the range check, as the reference's danger mode does, and the one-byte enum keeps the low byte (44)
// @xfail(raiser): Raiser converts an integer into an enum without a range check and prints bad=300 (same on the baseline)
// note: an integer converted into an enum is checked against the enum's lowest and highest member at run time, a value in a hole between them passes; 300 into a three-member enum stops the program on C and JS instead of storing 44 in its one byte.

enum Kind { A, B, C }
enum Holes { P = 1, Q = 5, R = 9 }

function opaque(x: int32): int32 { return x; }
function toKind(x: int32): Kind { return x as Kind; }

const inRange = toKind(opaque(2));
const hole = opaque(3) as Holes;
const member = Kind.B as Kind;
console.log(`in=${inRange as int32} hole=${hole as int32} member=${member as int32}`);
const bad = toKind(opaque(300));
console.log(`bad=${bad as int32}`);
console.log("after");
