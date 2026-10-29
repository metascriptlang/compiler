// Parity program — a number literal compared with a nullable union holding a number equals it when
// the member does, for == === != !==, either side, whether the union is a field, a local or a
// parameter, on every backend.
//
// @stdout: field=true,false,false,true,true
// @stdout: local=true,false,true,false
// @stdout: param=true,false,false
// @exit: 0

interface Style { width?: float64 | string; height: float64 | string | null; }

function mk(w: float64): Style { return { width: w, height: w }; }
function pick(k: int32): float64 | string | null { return k == 0 ? 20 : k == 1 ? "x" : null; }
function is20(v: float64 | string | null): boolean { return v === 20; }

const s = mk(18);
console.log(`field=${s.width === 18},${s.width === 19},${s.height !== 18},${s.height !== 20},${18 === s.width}`);
const u = pick(0);
console.log(`local=${u === 20},${u === 21},${u != 21},${u !== 20}`);
console.log(`param=${is20(pick(0))},${is20(pick(1))},${is20(pick(2))}`);
