// @stdout: widths -128 2 24464 32767 -1 7 1

function shift(value: int8, count: int8): int8 { return value << count; }
function multiply(left: int16, right: int16): int16 { return left * right; }
function divide(left: uint16, right: uint16): uint16 { return left / right; }
function remainder(left: int64, right: int64): int64 { return left % right; }
let locations: int32 = 0;
function index(): int32 { locations += 1; return 0; }
function divideSlot(values: int32[], divisor: int32): void { values[index()] /= divisor; }
const values: int32[] = [21];
divideSlot(values, 3);
console.log(`widths ${shift(1, 7)} ${shift(1, 9)} ${multiply(300, 300)} ${divide(65535, 2)} ${remainder(-7, 2)} ${values[0]} ${locations}`);
