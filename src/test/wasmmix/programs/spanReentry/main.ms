// @stdout: 15
// @stdout: 3.5
// @stdout: 14
// @foreign-stdout: writable: Error: a wasm function was called while a Span was lent to a JS callback: the call could move or change the elements the callback's Span sees, so call it after the callback returns
// @foreign-stdout: writable result: 15
// @foreign-stdout: readonly: Error: a wasm function was called while a Span was lent to a JS callback: the call could move or change the elements the callback's Span sees, so call it after the callback returns
// @foreign-stdout: readonly result: 3.5
// @foreign-stdout: nested lend: Error: a wasm function was called while a Span was lent to a JS callback: the call could move or change the elements the callback's Span sees, so call it after the callback returns
// @foreign-stdout: after the lend: 6
// @foreign-stdout: outer result: 6
// @foreign-stdout: later call: 8
import { lendWritable, lendReadonly, outer, twice } from "./spanReentryWasm";
export { lendWritable, lendReadonly, outer, twice } from "./spanReentryWasm";

console.log(`${lendWritable((xs: Span<int32>): void => {
	xs[0] = xs[0] + 9;
})}`);
console.log(`${lendReadonly((xs: Readonly<Span<float64>>): float64 => xs[0] + xs[1])}`);
console.log(`${outer((n: int32): int32 => twice(n))}`);
