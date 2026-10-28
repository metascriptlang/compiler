// @stdout: q7 q7 3|v9 2 w v9|n5 n5 1|6 z
// note: a `struct` match union's arm passed to a generic function is stored twice in an array:
// each slot is a copy with its own string, list and nested struct, released once.
enum K { R, P, L, N }
struct Inner { tag: string }
struct G<T> = match (kind: K) {
	K.R => { y: string },
	K.P => { w: string, x: T },
	K.L => { items: string[] },
	K.N => { inner: Inner, count: int32 },
};

function hold<T>(v: T): T[] { return [v, v]; }

function stringPayload(n: int32): string {
	const g: G<int32> = { kind: K.P, w: "q" + String(n), x: 3 };
	if (g.kind == K.P) { const xs = hold(g); return `${xs[0].w} ${xs[1].w} ${xs[1].x}`; }
	return "none";
}

function listPayload(n: int32): string {
	const g: G<int32> = { kind: K.L, items: ["v" + String(n), "w"] };
	if (g.kind == K.L) {
		const xs = hold(g);
		return `${xs[1].items[0]} ${xs[1].items.length} ${xs[0].items[1]} ${g.items[0]}`;
	}
	return "none";
}

function nestedPayload(n: int32): string {
	const g: G<int32> = { kind: K.N, inner: { tag: "n" + String(n) }, count: 1 };
	if (g.kind == K.N) { const xs = hold(g); return `${xs[0].inner.tag} ${xs[1].inner.tag} ${xs[1].count}`; }
	return "none";
}

function twoInstances(): string {
	const a: G<number> = { kind: K.P, w: "a", x: 5 };
	const b: G<string> = { kind: K.P, w: "b", x: "z" };
	if (a.kind == K.P && b.kind == K.P) {
		const xs = hold(a);
		const ys = hold(b);
		return `${xs[1].x + 1} ${ys[1].x}`;
	}
	return "none";
}

console.log([stringPayload(7), listPayload(9), nestedPayload(5), twoInstances()].join("|"));
