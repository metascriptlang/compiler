import { factor } from "./topLevelOnceHelper";

function noisy(label: string): int32 {
	console.log(label);
	return 1;
}

const unread: int32 = noisy("unread initialized");

console.log("placed ready");

@wasm
export function twice(x: int32): int32 {
	return x * factor();
}
