// @stdout: i32=1,-2,3 i64=10|20 u8=104,105,255 bool=true,false f64=1.5-2 str=a+b empty=[] one=42
// note: `join` takes an array of any element type, each element written as `${x}` writes it, as TypeScript does for every array; before, C had `join` only on number[] and string[], so `int32[].join(",")` was "Property 'join' does not exist on type 'Array'"; a uint8[] must not reach the number[] fast path, which reads 8-byte elements.
const ints: int32[] = [1, -2, 3];
const wides: int64[] = [10, 20];
const bytes: uint8[] = [104, 105, 255];
const flags: boolean[] = [true, false];
const floats: number[] = [1.5, 2];
const words: string[] = ["a", "b"];
const none: int32[] = [];
const single: int32[] = [42];
console.log(`i32=${ints.join(",")} i64=${wides.join("|")} u8=${bytes.join(",")} bool=${flags.join(",")} f64=${floats.join("-")} str=${words.join("+")} empty=[${none.join(",")}] one=${single.join(",")}`);
