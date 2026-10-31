// @stdout: -2147483648
// @stdout: 2147483647
// @stdout: 255
// @stdout: 9223372036854775807
// @stdout: -9223372036854775807
// @stdout: 18446744073709551614
// @stdout: true
// @stdout: []
// @stdout: hé😀
// @stdout: 0
// @stdout: 6
// @stdout: 2147483647
// @stdout: 2
// @stdout: 9007199254740995
// @stdout: 7
// @stdout: 1.5
// @stdout: 0
// @stdout: 41
// @stdout: true
// @foreign-stdout: exports: ok
// @foreign-stdout: valid: ok 42
// @foreign-stdout: string: TypeError: addI32: parameter 'a' expected int32, found string
// @foreign-stdout: missing: TypeError: addI32: parameter 'b' expected int32, found undefined
// @foreign-stdout: range: RangeError: addI32: parameter 'a' expected int32, got 2147483648
// @foreign-stdout: fraction: RangeError: addI32: parameter 'a' expected int32, got 1.5
// @foreign-stdout: nan: RangeError: addI32: parameter 'a' expected int32, got NaN
// @foreign-stdout: u8: RangeError: lowByte: parameter 'a' expected uint8, got 256
// @foreign-stdout: i64 number: TypeError: echo64: parameter 'a' expected int64, found number
// @foreign-stdout: u64 range: RangeError: echoU64: parameter 'a' expected uint64, got -1
// @foreign-stdout: bool: TypeError: not: parameter 'b' expected boolean, found number
// @foreign-stdout: float nan: ok NaN
// @foreign-stdout: str: TypeError: join2: parameter 'b' expected string, found number
// @foreign-stdout: struct null: TypeError: reach: parameter 's' expected object, found null
// @foreign-stdout: struct nested: TypeError: reach: parameter 's' field 'stop' expected object, found undefined
// @foreign-stdout: struct leaf: TypeError: reach: parameter 's' field 'stop.y' expected float64, found undefined
// @foreign-stdout: struct ok: ok 7
// @foreign-stdout: vec text: TypeError: sumVec: parameter 'xs' expected Vec<int32>, found string
// @foreign-stdout: vec element: TypeError: sumVec: parameter 'xs' element 1 expected int32, found string
// @foreign-stdout: vec range: RangeError: sumVec: parameter 'xs' element 1 expected int32, got 2.5
// @foreign-stdout: bool vec: TypeError: countTrue: parameter 'bs' element 1 expected boolean, found number
// @foreign-stdout: i64 vec: TypeError: bigSum: parameter 'xs' element 1 expected int64, found number
// @foreign-stdout: span shape: TypeError: sumSpan: parameter 'xs' expected Span<float32> with integer off and len, got off 0.5 len 1
// @foreign-stdout: span empty: ok 0
// @foreign-stdout: callback type: TypeError: evalCb: parameter 'cb' expected function, found string
// @foreign-stdout: callback result: TypeError: evalCb: result of callback 'cb' expected int32, found string
// @foreign-stdout: callback bool: TypeError: testCb: result of callback 'cb' expected boolean, found number
import { addI32, lowByte, echo64, echoU64, not, join2, sumVec, countTrue, bigSum, reach, sumSpan, evalCb, testCb } from "./devChecksWasm";
export { addI32, lowByte, echo64, echoU64, not, half, join2, sumVec, countTrue, bigSum, reach, sumSpan, evalCb, testCb } from "./devChecksWasm";

console.log(`${addI32(-2147483648, 0)}`);
console.log(`${addI32(2147483647, 0)}`);
console.log(`${lowByte(255)}`);
console.log(`${echo64(9223372036854775807)}`);
console.log(`${echo64(-9223372036854775807)}`);
const top: uint64 = 9223372036854775807;
console.log(`${echoU64(top + top)}`);
console.log(`${not(false)}`);
console.log(`[${join2("", "")}]`);
console.log(`${join2("hé", "😀")}`);
const none: Vec<int32> = [];
console.log(`${sumVec(none)}`);
const xs: Vec<int32> = [1, 2, 3];
console.log(`${sumVec(xs)}`);
const edge: Vec<int32> = [2147483647, 0];
console.log(`${sumVec(edge)}`);
const bs: Vec<boolean> = [true, false, true];
console.log(`${countTrue(bs)}`);
const big: Vec<int64> = [9007199254740993, 2];
console.log(`${bigSum(big)}`);
console.log(`${reach({ start: { x: 1, y: 2 }, stop: { x: 4, y: 6 }, tag: "t", lit: true })}`);
const fv: Vec<float32> = [1.5, 2, -0.5, 4];
console.log(`${sumSpan(fv[1..3])}`);
console.log(`${sumSpan(fv[7..7])}`);
console.log(`${evalCb(20, (x: int32): int32 => x * 2)}`);
console.log(`${testCb(3, (x: int32): boolean => x > 2)}`);
