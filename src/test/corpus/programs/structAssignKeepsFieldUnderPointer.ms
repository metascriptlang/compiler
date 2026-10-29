// @stdout: swap=21 interior=2 fromLocal=31 interior=33 nested=21 interior=2 kept=12
// note: a whole struct assigned from a literal that reads fields of the destination keeps each field where it is, so a pointer to a field sees the new value, as C does.
struct In { v: int32; }
struct Pair { a: In; b: In; }
struct Holder { p: Pair; }

function churn(): In[] {
	const keep: In[] = [];
	for (let i = 0; i < 4; i += 1) keep.push({ v: 50 + i });
	return keep;
}

function main(): void {
	let s: Pair = { a: { v: 1 }, b: { v: 2 } };
	const pa = s.a as Ptr<In>;
	s = { a: s.b, b: s.a };
	const k1 = churn();
	let l: Pair = { a: { v: 1 }, b: { v: 2 } };
	const pl = l.a as Ptr<In>;
	const t: In = { v: 3 };
	l = { a: t, b: l.a };
	const k2 = churn();
	let h: Holder = { p: { a: { v: 1 }, b: { v: 2 } } };
	const ph = h.p.a as Ptr<In>;
	h.p = { a: h.p.b, b: h.p.a };
	const k3 = churn();
	console.log(`swap=${s.a.v}${s.b.v} interior=${pa.v} fromLocal=${l.a.v}${l.b.v} interior=${pl.v}${t.v} nested=${h.p.a.v}${h.p.b.v} interior=${ph.v} kept=${k1.length + k2.length + k3.length}`);
}
main();
