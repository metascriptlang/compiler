// @stdout: 255 65535 4294967295 18446744073709551615 | 127 32767 2147483647 9223372036854775807 | 127 32767 9223372036854775807 | 124 32764
// note: `>>>` reads a signed operand's bits as the unsigned type of its own width and has that type, as an int32 gives a uint32: by 0, by 1, by a count masked to the width (9 on int8, 17 on int16, 65 on int64), and on an array element.

let i8: int8 = -1;
let i16: int16 = -1;
let i32: int32 = -1;
let i64: int64 = -1;
let z8: int8 = 0;
let z16: int16 = 0;
let z32: int32 = 0;
let z64: int64 = 0;
const a8: uint8 = i8 >>> z8;
const a16: uint16 = i16 >>> z16;
const a32: uint32 = i32 >>> z32;
const a64: uint64 = i64 >>> z64;
let o8: int8 = 1;
let o16: int16 = 1;
let o32: int32 = 1;
let o64: int64 = 1;
const b8: uint8 = i8 >>> o8;
const b16: uint16 = i16 >>> o16;
const b32: uint32 = i32 >>> o32;
const b64: uint64 = i64 >>> o64;
let m8: int8 = 9;
let m16: int16 = 17;
let m64: int64 = 65;
const small: int8[] = [-8];
const mid: int16[] = [-8];
console.log(`${a8} ${a16} ${a32} ${a64} | ${b8} ${b16} ${b32} ${b64} | ${i8 >>> m8} ${i16 >>> m16} ${i64 >>> m64} | ${small[0] >>> o8} ${mid[0] >>> o16}`);
