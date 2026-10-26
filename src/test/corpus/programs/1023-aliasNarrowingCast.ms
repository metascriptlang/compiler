// @stdout: 44 4464 3 42
// note: a cast to a type alias converts like a cast to the aliased integer type on every backend (JS printed 300 70000 3.9 42: the conversion was chosen from the cast's spelling, and an alias name matched no integer kind).

type Big = bigint;
type Byte = uint8;
type Half = uint16;
type Whole = int32;

function wide(n: int32): int32 { return n; }
function frac(f: float64): float64 { return f; }

const a = wide(300) as Byte;
const h = wide(70000) as Half;
const w = frac(3.9) as Whole;
const g = (wide(6) as Big) * (wide(7) as Big);
console.log(`${a} ${h} ${w} ${g}`);
