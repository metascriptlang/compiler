import { hasError, strictErrorCount } from "./helpers";

test "a tuple index that folds to a constant inside the tuple is accepted" {
	const sources = [
		"function f(): string { const t: [int32, string] = [1, \"a\"]; return t[1]; }",
		"const K = 1;\nfunction f(): string { const t: [int32, string] = [1, \"a\"]; return t[K]; }",
		"function f(): string { const t: [int32, string] = [1, \"a\"]; return t[0 + 1]; }",
	];
	for (const source of sources) {
		assert strictErrorCount(source) == 0, source;
	}
}

test "a tuple index that folds outside the tuple is refused with its folded value" {
	const cases = [
		{ source: "function f(): int32 { const t: [int32, string] = [1, \"a\"]; t[2]; return 0; }", needle: "index 2 out of bounds for a tuple of length 2" },
		{ source: "function f(): int32 { const t: [int32, string] = [1, \"a\"]; t[5]; return 0; }", needle: "index 5 out of bounds for a tuple of length 2" },
		{ source: "function f(): int32 { const t: [int32, string] = [1, \"a\"]; t[-1]; return 0; }", needle: "index -1 out of bounds for a tuple of length 2" },
		{ source: "const K = 5;\nfunction f(): int32 { const t: [int32, string] = [1, \"a\"]; t[K]; return 0; }", needle: "index 5 out of bounds for a tuple of length 2" },
	];
	for (const item of cases) {
		assert strictErrorCount(item.source) == 1, item.source;
		assert hasError(item.source, item.needle), item.source;
	}
}

test "a tuple index without a constant value is refused" {
	const sources = [
		"function f(i: int32): int32 { const t: [int32, int32] = [1, 2]; return t[i]; }",
		"function f(): int32 { let i = 1; const t: [int32, int32] = [1, 2]; return t[i]; }",
	];
	for (const source of sources) {
		assert strictErrorCount(source) == 1, source;
		assert hasError(source, "a tuple index must be a constant"), source;
	}
}
