export type Bytes = uint8[] & { __brand: "Bytes" };
export type Holds = string | Bytes;

export function bytesOf(): Bytes {
	const a: uint8[] = [1, 2, 3];
	return a as Bytes;
}

export function holds(h: Holds): string {
	if (typeof h == "string") return `s${h.length}`;
	return `b${h.length}`;
}
