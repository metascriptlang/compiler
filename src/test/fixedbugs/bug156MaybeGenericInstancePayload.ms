// bug156 — every `Maybe` over an instance of one generic shared a single wrapper type
//
// Symptom:    `interface Q { a?: Acc<number> | null; b?: Acc<string> | null; }` typed `q.b` as
//             `Acc<number>` (`Return type mismatch: expected string, got number`); the same with a
//             generic alias `Th<T> = () => T`; Found by Neon's Pressable, whose
//             `delayLongPress?: Accessor<number> | null` was checked as `Accessor<Style>`.
//
// Root cause: maybeCacheKey keyed the wrapper by `inner.typeName`, which for a generic instance is
//             the bare generic name, so `Acc<number> | null` and `Acc<string> | null` resolved to the
//             first wrapper created.
//
// Fix:        a generic instance is keyed by its full instance key (typeKey), like a function type.

type Acc156<T> = distinct (() => T);
export function valueOf<T>(this a: Acc156<T>): T { return a(); }
interface Q156 { a?: Acc156<number> | null; b?: Acc156<string> | null; }
type Th156<T> = () => T;
interface R156 { a?: Th156<number> | null; b?: Th156<string> | null; }

function readB156(q: Q156): string { if (q.b != null) { return q.b; } return "none"; }
function readA156(q: Q156): number { if (q.a != null) { return q.a + 1; } return 0; }
function callB156(r: R156): string { if (r.b != null) { return r.b(); } return "none"; }
function callA156(r: R156): number { if (r.a != null) { return r.a() + 1; } return 0; }

test "bug156: two nullable accessor fields read their own payloads" {
	const q: Q156 = { a: (() => 1) as Acc156<number>, b: (() => "x") as Acc156<string> };
	assert readB156(q) === "x";
	assert readA156(q) === 2;
	const empty: Q156 = { a: null, b: null };
	assert readB156(empty) === "none";
	assert readA156(empty) === 0;
}

test "bug156: two nullable alias-instance fields read their own payloads" {
	const r: R156 = { a: () => 5, b: () => "y" };
	assert callB156(r) === "y";
	assert callA156(r) === 6;
}
