// @stdout: first=1 loop=3 len=4 bytes=97 bump=7 7 heap=1 8 text=4
// note: a view read before its source changes, a view re-taken each iteration, and a local's address that stays in its frame compile and agree on every lane.

struct S { n: int32; }

function bump(p: Ptr<S>): void {
	p[].n = p[].n + 1;
}

function first(xs: S[]): Ptr<S> {
	return xs[0] as Ptr<S>;
}

function firstOf(ref s: S): Ptr<S> {
	return s as Ptr<S>;
}

function main(): void {
	let xs: S[] = [{ n: 1 }];
	const sp: Span<S> = xs;
	const head = sp[0].n;
	xs.push({ n: 2 });
	let total: int32 = 0;
	for (let i = 0; i < 2; i++) {
		const view: Span<S> = xs;
		total += view[i].n;
		xs.push({ n: i });
	}
	const text = "ab" + String(1);
	const bytes = text.asBytes();
	const longer = text + "!";
	let s: S = { n: 5 };
	const p = s as Ptr<S>;
	bump(p);
	bump(s as Ptr<S>);
	let t: S = { n: 8 };
	console.log(`first=${head} loop=${total} len=${xs.length} bytes=${bytes[0]} bump=${s.n} ${p[].n} heap=${first(xs)[].n} ${firstOf(t)[].n} text=${longer.length}`);
}

main();
