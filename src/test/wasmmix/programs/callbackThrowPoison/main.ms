// @stdout: 3
// @foreign-stdout: original error: true
// @foreign-stdout: after: Error: the wasm half cannot run again: a JS exception crossed its frames
// @foreign-stdout: after, another export: Error: the wasm half cannot run again: a JS exception crossed its frames
// @foreign-stdout: cause: true
// @foreign-stdout: other instance: ok 4
// @foreign-stdout: nested original: true
// @foreign-stdout: after nested: Error: the wasm half cannot run again: a JS exception crossed its frames
import { guarded } from "./callbackThrowPoisonWasm";
export { guarded, recover } from "./callbackThrowPoisonWasm";

console.log(`${guarded(1, (x: int32): int32 => x * 2)}`);
