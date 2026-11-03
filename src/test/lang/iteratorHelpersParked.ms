// Parked at inbox card 2026-11-02-iterator-result-of-a-nullable-element-fails-c.md

test "iterator reduce: without an initial value through the closure path keeps a single null element" {
	const none: (string | null)[] = [null];
	assert none.values().reduce((a: string | null, s: string | null, i: number): string | null => "never") == null;
}
