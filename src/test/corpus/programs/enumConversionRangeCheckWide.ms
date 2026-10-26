// @exit: 1
// @stdout: low=256 high=70000
// @xfail(danger): --danger drops the range check, as the reference's danger mode does, and the two-byte enum keeps the low 16 bits
// note: an int64 converted into a two-byte enum is checked against the enum's lowest and highest member at run time; a value one past the highest member stops the program on C and JS.

enum Port { Low = 256, Mid = 1000, High = 70000 }

function opaque(x: int64): int64 { return x; }
function toPort(x: int64): Port { return x as Port; }

console.log(`low=${toPort(opaque(256)) as int32} high=${toPort(opaque(70000)) as int32}`);
console.log(`past=${toPort(opaque(70001)) as int32}`);
console.log("after");
