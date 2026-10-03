// @stdout: indexed 7 1 238 2 1 0

let calls: int32 = 0;
function index(): int32 { calls += 1; return 0; }
let selected: int32 = 0;
let skipped: int32 = 0;
function divisor(): int32 { selected += 1; return 3; }
function other(): int32 { skipped += 1; return 0; }
function divide(values: int32[], choose: boolean): void { values[index()] /= choose ? divisor() : other(); }
function multiply(values: uint8[], factor: uint8): void { values[index()] *= factor; }

const ints: int32[] = [21];
const bytes: uint8[] = [250 as uint8];
divide(ints, calls == 0);
const first = calls;
multiply(bytes, 3 as uint8);
console.log(`indexed ${ints[0]} ${first} ${bytes[0]} ${calls} ${selected} ${skipped}`);
