// @stdout: 3 3
// @stdout: High set
// @foreign-stdout: exports: ok
// @foreign-stdout: valid: ok 2 2
// @foreign-stdout: not a cell: TypeError: bump: parameter 'n' expected ref int32 as [object, key], found number
// @foreign-stdout: short cell: TypeError: bump: parameter 'n' expected ref int32 as [object, key], found array
// @foreign-stdout: wrong value: TypeError: bump: parameter 'n' expected int32, found string
// @foreign-stdout: range: RangeError: bump: parameter 'n' expected int32, got 2147483648
// @foreign-stdout: out zero: ok 2 set
// @foreign-stdout: out other: ok 2 set
import { Level, bump, fill } from "./refForeignWasm";
export { bump, fill } from "./refForeignWasm";

let n: int32 = 2;
console.log(`${bump(n)} ${n}`);
let lvl: Level;
let s: string;
fill(out lvl, out s);
console.log(`${lvl} ${s}`);
