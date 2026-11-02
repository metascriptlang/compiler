import { LIMIT, Level, Pair, Counter, scale, word, seed } from "./leaf";

const SEEDED: int32 = @comptime { return seed(); };

export function midValue(): int32 {
	const c = new Counter();
	const p: Pair = { a: 1, b: 2 };
	return LIMIT * 100 + (Level.High as int32) * 10 + scale(1) + c.bump() + p.a + SEEDED;
}

export function midWord(): string {
	return word();
}
