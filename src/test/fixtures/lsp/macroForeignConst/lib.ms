import { scopeType } from "./probe";
import { Scope } from "./core";

export function view<P>(x: P): int32 {
	return scopeType("Scope");
}
