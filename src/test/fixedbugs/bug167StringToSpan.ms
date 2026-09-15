// bug167 — string → Span<char> read the byte pointer off the wrong struct
//
// Symptom:    every coercion from a string to a Span<char> — a declaration, a call argument, an `s[a..b]`
//             slice — died in clang with `no member named 'data' in 'msString'`. Every other Span source
//             (Vec<T>, Array<T>/T[], T[N]) coerced and ran.
// Root cause: transform/lowering/spanLower.ms emitted `{ data: str.data, len: str.len }`. `msString` is
//             `{ len; msStrPayload* p }` and the bytes live in the payload, so only `len` was on the struct
//             it was read from. The slice arm's comment claimed nativeLower rewrites `.data` to `.p->data`
//             for strings; that rewrite covers Array alone.
// Fix:        take the pointer the way the Array arm already does — `msArrDataOr0(str.p)`, NULL for the
//             empty string, whose `p` is NULL.

function count167(s: Span<char>): int32 {
	let n: int32 = 0;
	let i: int32 = 0;
	while (i < (s.length as int32)) {
		if ((s[i] as int32) == 99) { n = n + 1; }
		i = i + 1;
	}
	return n;
}

test "bug167: string coerces to Span<char> and reads its bytes" {
	const txt = "hello";
	const chars: Span<char> = txt;
	assert (chars.length as int32) == 5;
	assert (chars[0] as int32) == 104;
	assert (chars[4] as int32) == 111;
}

test "bug167: string literal meets a Span<char> parameter" {
	assert count167("accbc") == 3;
}

test "bug167: empty string yields an empty span, not a crash" {
	const empty = "";
	const none: Span<char> = empty;
	assert (none.length as int32) == 0;
}

test "bug167: slicing a string yields a span over its bytes" {
	const txt = "hello";
	const mid = txt[1..4];
	assert (mid.length as int32) == 3;
	assert (mid[0] as int32) == 101;
	assert (mid[2] as int32) == 108;
}

test "bug167: span over a heap-built string, and a slice of that span" {
	let built = "ab";
	built = built + "cdc";
	const s: Span<char> = built;
	assert (s.length as int32) == 5;
	assert count167(built) == 2;
	const inner = s[1..3];
	assert (inner.length as int32) == 2;
	assert (inner[0] as int32) == 98;
}

test "bug167: Span<char> over a string walks with for..of" {
	const txt = "abc";
	const s: Span<char> = txt;
	let total: int32 = 0;
	for (const c of s) { total = total + (c as int32); }
	assert total == 294;
}
