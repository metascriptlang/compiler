import { Box, padOf } from "./box";

export struct Holder {
	tag: int32;
	b: Box<int32>;
	last: int32;
}

export function describe(): string {
	const h: Holder = { tag: 1, b: { v: 2, pad: 3 }, last: 4 };
	return `${h.tag} ${padOf(h.b)} ${h.last}`;
}
