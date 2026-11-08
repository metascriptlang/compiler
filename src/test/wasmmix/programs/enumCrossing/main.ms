// @stdout: 1
// @stdout: Red
// @stdout: High
// @stdout: Big
// @stdout: 17
// @stdout: Green 4 Blue
// @stdout: Red none
// @stdout: Red
// @stdout: none
// @stdout: Blue
// @foreign-stdout: valid: ok 2
// @foreign-stdout: result: ok 0
// @foreign-stdout: range: RangeError: name: parameter 'c' expected Color, got 3
// @foreign-stdout: wide: RangeError: flip: parameter 'w' expected Wide, got 301
// @foreign-stdout: field: RangeError: level: parameter 'p' field 'shade' expected Color, got -1
// @foreign-stdout: nullable field: RangeError: level: parameter 'p' field 'tint' expected Color, got 9
// @foreign-stdout: nullable: RangeError: orRed: parameter 'c' expected Color, got 5
// @foreign-stdout: callback result: RangeError: relay: result of callback 'f' expected Color, got 4
// @foreign-stdout: after: ok 1
import { Color, Wide, Tall, Pixel, name, next, flip, grow, level, paint, orRed, relay } from "./enumCrossingWasm";
export { name, flip, level, orRed, relay } from "./enumCrossingWasm";

console.log(`${name(Color.Green)}`);
console.log(`${next(Color.Blue)}`);
console.log(`${flip(Wide.Low)}`);
console.log(`${grow(Tall.Short)}`);
const p: Pixel = { shade: Color.Blue, level: 5, tint: Color.Red };
console.log(`${level(p)}`);
const q = paint(Color.Green);
const qt = q.tint;
console.log(`${q.shade} ${q.level} ${qt != null ? `${qt}` : "none"}`);
const r = paint(Color.Red);
const rt = r.tint;
console.log(`${r.shade} ${rt != null ? `${rt}` : "none"}`);
const a = orRed(null);
console.log(a != null ? `${a}` : "none");
const b = orRed(Color.Green);
console.log(b != null ? `${b}` : "none");
console.log(`${relay(Color.Red, (x: Color): Color => x == Color.Red ? Color.Blue : Color.Green)}`);
