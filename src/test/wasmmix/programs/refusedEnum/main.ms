// @mixed-error: 'name' in ~> parameter 'c' has type ~> and an enum has no boundary form yet: cross its integer instead, passing 'x as int32', and converting back with 'n as Color', which checks the range
// @mixed-error: 'next' in ~> the result has type ~> and an enum has no boundary form yet: cross its integer instead, returning 'x as int32', and converting back with 'n as Color', which checks the range
// @mixed-error: 'level' in ~> field 'shade' of parameter 'p' has type ~> and an enum has no boundary form yet: cross its integer instead, declaring the field as int32 and writing 'x as int32', and converting back with 'n as Color', which checks the range
// @stdout: 1
// @stdout: 0
// @stdout: 7
import { Color, Pixel, name, next, level } from "./refusedEnumWasm";

console.log(`${name(Color.Green)}`);
console.log(`${next(2) as int32}`);
const p: Pixel = { shade: Color.Blue, level: 5 };
console.log(`${level(p)}`);
