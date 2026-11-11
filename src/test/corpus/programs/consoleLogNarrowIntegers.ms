// @stdout: -128 -32768 -2147483648
// @stdout: 255 65535 4294967295
// @stdout: 2147483647 null
// @stdout: n=-21474836484294967295
const i8: int8 = -128;
const i16: int16 = -32768;
const i32: int32 = -2147483648;
const u8: uint8 = 255;
const u16: uint16 = 65535;
const u32: uint32 = 4294967295;
const some: int32 | undefined = 2147483647;
const none: int32 | undefined = undefined;
let text = "n=";
text += i32;
text += u32;
console.log(i8, i16, i32);
console.log(u8, u16, u32);
console.log(some, none);
console.log(text);
