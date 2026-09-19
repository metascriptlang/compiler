import { reexportDirectiveAdd, reexportDirectiveMul, reexportDirectiveSub } from "./bridge.h";

export function add(a: int32, b: int32): int32 {
	return reexportDirectiveAdd(a, b);
}

export function mul(a: int32, b: int32): int32 {
	return reexportDirectiveMul(a, b);
}

export function sub(a: int32, b: int32): int32 {
	return reexportDirectiveSub(a, b);
}
