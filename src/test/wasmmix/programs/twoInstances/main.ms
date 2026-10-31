// @stdout: 41
// @stdout: -3
// @stdout: 8
// @stdout: 4 hi!
// @stdout: 0,0.5,1
// @foreign-stdout: a apply: ok 41
// @foreign-stdout: a measure: ok 8
// @foreign-stdout: a pair: ok 4 hi!
// @foreign-stdout: a ramp: ok 0,0.5,1
// @foreign-stdout: b apply: ok 121
// @foreign-stdout: b measure: ok 10
// @foreign-stdout: b pair: ok 8 yo!
// @foreign-stdout: b ramp: ok 0,0.5
// @foreign-stdout: cross: ok -3
// @foreign-stdout: a after b: ok 41
// @foreign-stdout: no registry: Error: msb registry missing: pass { msb } to the wasm module factory
import { apply, measure, pair, ramp } from "./twoInstancesWasm";
export { apply, measure, pair, ramp } from "./twoInstancesWasm";

console.log(`${apply(20, (x: int32): int32 => x * 2)}`);
console.log(`${apply(1, (x: int32): int32 => apply(x, (y: int32): int32 => y - 6))}`);
console.log(`${measure((s: string): int32 => s.length)}`);
const p = pair(3, "hi");
console.log(`${p.left} ${p.name}`);
console.log(ramp(3).join(","));
