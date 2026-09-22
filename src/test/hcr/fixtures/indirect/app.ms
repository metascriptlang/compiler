import { base, pair, value } from "./logic";

@exportName("hcrIndirectValue")
export function hcrIndirectValue(): int32 {
	const read: () => int32 = base;
	return value() + pair(10).second + read();
}
