// @stdout: helper ready
// @stdout: entry start
// @stdout: base initialized
// @stdout: 42
// @stdout: 43
// @stdout: entry end
import { factor } from "./entryPlacedHelper";

function noisy(label: string, v: int32): int32 {
	console.log(label);
	return v;
}

console.log("entry start");

const base: int32 = noisy("base initialized", 1);

@wasm
export function twice(x: int32): int32 {
	return x * factor();
}

@wasm
export function plusBase(x: int32): int32 {
	return x + base;
}

console.log(`${twice(21)}`);
console.log(`${plusBase(42)}`);
console.log("entry end");
