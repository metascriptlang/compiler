import { value } from "./logic";

@exportName("hcrObjectCacheValue")
export function hcrObjectCacheValue(): int32 {
	return value() as int32;
}
