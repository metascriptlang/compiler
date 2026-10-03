export interface WireShape { a: int32; }

export function fixtureShapeValue(): int32 {
	const s: WireShape = { a: 5 };
	return s.a;
}
