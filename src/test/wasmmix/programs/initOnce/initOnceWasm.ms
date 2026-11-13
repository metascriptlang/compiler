import { base } from "./initOnceHelper";

function loud(label: string, v: int32): int32 {
	console.log(label);
	return v;
}

function pair(): int32[] {
	console.log("pair");
	return [1, 2];
}

console.log("kernel a");
const k: int32 = loud("kernel k", 3);
export class Cfg {
	static readonly scale: int32 = loud("static scale", 2);
}
const [lo, hi] = pair();
{
	const once: int32 = loud("block local", 1);
}
console.log("kernel b");
export const stamp: float64 = Math.random();
const unread: int32 = loud("unread", 0);

@wasm
export function calc(): float64 {
	return (k * Cfg.scale * (lo + hi)) as float64 + base;
}

export function hiFromJs(): int32 {
	return hi;
}

@wasm
export function stampInWasm(): float64 {
	return stamp;
}
