// Parked at inbox card 2026-09-27-result-value-union-projection.md

enum CodecKind { Click, Key }

interface CodecClick { kind: CodecKind.Click; x: int32; }

interface CodecKey { kind: CodecKind.Key; code: int32; }

type CodecEvent = CodecClick | CodecKey;

test "macro enum codec: each narrowed discriminant round-trips with its payload" {
	const values: CodecEvent[] = [
		{ kind: CodecKind.Click, x: 7 },
		{ kind: CodecKind.Key, code: 42 },
	];
	for (const value of values) {
		const text = JSON.stringify(value);
		const parsed = JSON.parse<CodecEvent>(text);
		assert parsed.ok;
		if (parsed.value.kind == CodecKind.Click) assert parsed.value.x == 7;
		else assert parsed.value.code == 42;
	}
}
