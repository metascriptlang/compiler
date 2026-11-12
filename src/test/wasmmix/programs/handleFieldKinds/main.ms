// @stdout: -128 255 -32768 65535 -2147483648 4294967295
// @stdout: -9007199254740993 18446744073709551615 1.25 -2.5 true true true
// @stdout: 7 201 -5 60000 123456790 4000000000 9007199254740993 5 0.5 1024.5 false 2 -1
// @stdout: 3000000
// @stdout: 123456790 1024.5 false
// @stdout: 7 201 -5 1 123456790 4000000000 9007199254740993 5 0.5 1024.5 false 2 -1
import { Handle } from "std/ffi";
import { Mode, Level, open, grow } from "./handleFieldKindsWasm";

const h = open();
console.log(`${h.value().s8} ${h.value().u8} ${h.value().s16} ${h.value().u16} ${h.value().s32} ${h.value().u32}`);
console.log(`${h.value().s64} ${h.value().u64} ${h.value().f32} ${h.value().f64} ${h.value().on} ${h.value().mode == Mode.Busy} ${h.value().level == Level.High}`);
h.value().s8 = 7;
h.value().u8 = 200;
h.value().s16 = -5;
h.value().u16 = 60000;
h.value().s32 = 123456789;
h.value().u32 = 4000000000;
h.value().s64 = 9007199254740993;
h.value().u64 = 5;
h.value().f32 = 0.5;
h.value().f64 = 1024.5;
h.value().on = false;
h.value().mode = Mode.Done;
h.value().level = Level.Low;
h.value().s32 += 1;
h.value().u8++;
console.log(h.value().describe());
console.log(`${grow(3000000)}`);
console.log(`${h.value().s32} ${h.value().f64} ${h.value().on}`);
h.value().u16 = 1;
console.log(h.value().describe());
h.release();
