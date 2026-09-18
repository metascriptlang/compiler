// bug186 — narrowing a nullable union by dropping a member type reinterpreted the carrier
// Symptom: `const a: number | string | null = "row"; a as string | null` completed the cast and then
//          panicked on the first read — `Maybe{ msUnion value; bool present }` and `Maybe{ msString value;
//          bool present }` have different layouts, so `present` loaded a payload byte (`load of value 8,
//          which is not valid for type 'MS_BOOL'`). The JS lane was correct throughout.
// Root cause: the checker built no conversion for the assertion, so codegen fell through to the
//             nilable-value arm and emitted `*(Maybe_p1*)&(a)` — the shape Nim reserves for `nkObjUpConv`,
//             where a prefix layout and an `isObj` check make it sound (ccgexprs.nim:3343).
// Fix: the asserted narrowing takes the same conversion the flow-narrowed read already takes
//      (narrowMaybePayload), and the emitted projection raises when the carrier holds another member.

function takesNarrow186(v: string | null): string { return v === null ? "N" : "V"; }
function takesNum186(v: number | null): string { return v === null ? "N" : "V"; }
function takesBare186(v: string): string { return v; }
function takesWide186(v: number | string | null): string { return v === null ? "N" : "V"; }

test "dropping a member type keeps the carrier readable" {
	const a: number | string | null = "row";
	const got = takesNarrow186(a as string | null);
	console.log("bug186 narrowed=" + got);
	assert got == "V";
}

test "the narrowed carrier reads its payload, not the tag bytes" {
	const a: number | string | null = "row";
	const n: string | null = a as string | null;
	assert n !== null;
	assert n == "row";
}

test "an absent carrier narrows to absent" {
	const a: number | string | null = null;
	const n: string | null = a as string | null;
	assert n === null;
	assert takesNarrow186(n) == "N";
}

test "the number member narrows through the same conversion" {
	const a: number | string | null = 42;
	const n: number | null = a as number | null;
	assert n !== null;
	assert n == 42;
	assert takesNum186(a as number | null) == "V";
}

test "dropping only null still works" {
	const b: string | null = "row";
	assert takesBare186(b as string) == "row";
}

test "the wide union is unchanged without a cast" {
	const a: number | string | null = "row";
	assert takesWide186(a) == "V";
}
