// @stdout: 3
// @foreign-stdout: original error: true
// @foreign-stdout: after: ok 3
// @foreign-stdout: same text kept the original: true
// @foreign-stdout: rewritten text: Error: seen: marker, original: false
// @foreign-stdout: wasm throw: Error: wasm blew 5
// @foreign-stdout: after wasm throw: ok 4
// @foreign-stdout: trap threw: true
// @foreign-stdout: after trap: Error: the wasm half cannot run again: a trap or a host error left its frames unfinished
// @foreign-stdout: cause is the trap: true
// @foreign-stdout: other instance: ok 6
// @foreign-stdout: nested trap reaches the outer caller: true
// @foreign-stdout: after nested trap: Error: the wasm half cannot run again: a trap or a host error left its frames unfinished
import { guarded } from "./callbackThrowPoisonWasm";
export { guarded, rethrow, blow, wild } from "./callbackThrowPoisonWasm";

console.log(`${guarded(1, (x: int32): int32 => x * 2)}`);
