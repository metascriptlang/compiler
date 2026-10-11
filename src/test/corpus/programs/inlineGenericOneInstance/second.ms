import { viaTry, viaMatch, viaNullish, viaErr, tally } from "./lib";

export function second(v: int32): string {
	const t = tally(viaTry<int32>(v, v * 2));
	const m = viaMatch<int32>(v, 10, 20);
	const z = viaNullish<int32>(v > 1 ? v : null, -1);
	const e = tally(viaErr<int32>(v - 2, v));
	return `second ${t} ${m} ${z} ${e}`;
}
