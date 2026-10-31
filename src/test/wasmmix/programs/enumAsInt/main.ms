// @stdout: 1
// @stdout: 0
// @stdout: 7
import { Color, Pixel, name, next, level } from "./enumAsIntWasm";

console.log(`${name(Color.Green as int32)}`);
console.log(`${next(2)}`);
const p: Pixel = { shade: Color.Blue as int32, level: 5 };
console.log(`${level(p)}`);
