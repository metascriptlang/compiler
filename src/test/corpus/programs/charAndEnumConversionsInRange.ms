// note: a conversion into char inside 0 .. 255 keeps the value or truncates a float, and an enum converts to an integer or float type as its ordinal does, the same on C, JS and the Raiser.

enum E { Neg = -5, Big = 1000000000 }

function toChar(v: int32): char { return v as char; }
function floatToChar(v: float64): char { return v as char; }
function charToI8(c: char): int8 { return c as int8; }

const ints: int32[] = [0, 65, 255, 127, 200];
const floats: float64[] = [-0.5, 65.9, 255.99];
const e: E[] = [E.Neg, E.Big];
console.log(`char ${toChar(ints[0]) as int32} ${toChar(ints[1]) as int32} ${toChar(ints[2]) as int32}`);
console.log(`float ${floatToChar(floats[0]) as int32} ${floatToChar(floats[1]) as int32} ${floatToChar(floats[2]) as int32}`);
console.log(`narrow ${charToI8(toChar(ints[3]))} ${toChar(ints[4]) as int16} ${toChar(ints[4]) as uint8}`);
console.log(`enum ${e[0] as uint8} ${e[0] as uint16} ${e[1] as uint8} ${e[1] as int32} ${e[1] as float64} ${e[0] as float32}`);
