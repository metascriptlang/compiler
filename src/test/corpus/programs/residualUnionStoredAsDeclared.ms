// @stdout: generic=true,wide two=true,zed arr=true,true anon=true field=true back=true,wide
// @stdout: enum generic=true,wide two=true,zed arr=true,true anon=true back=true,wide
// note: a union narrowed by != to two of its three variants is a smaller C struct than the declared union it is stored as; a read that nothing else converts (a generic argument, an array element, an anonymous object field) takes the narrowed layout through the conversion that tag-checks each member, so the held member survives instead of being read through the wrong tag. One program per kind of discriminator: a string literal one and an enum-matched one.

enum K { A, B, C }

type Shape = { kind: "a", r: string } | { kind: "b", w: string } | { kind: "c", z: string };

type Tagged = match (kind: K) {
	K.A => { r: string },
	K.B => { w: string },
	K.C => { z: string },
};

function make(i: int32): Shape {
	if (i == 0) return { kind: "a", r: "round" };
	if (i == 1) return { kind: "b", w: "wide" };
	return { kind: "c", z: "zed" };
}

function makeTagged(i: int32): Tagged {
	if (i == 0) return { kind: K.A, r: "round" };
	if (i == 1) return { kind: K.B, w: "wide" };
	return { kind: K.C, z: "zed" };
}

function id<T>(x: T): T {
	return x;
}

function second<T>(x: T, y: T): T {
	return y;
}

function declaredAgain(s: Shape): Shape {
	if (s.kind != "a") return s;
	return { kind: "b", w: "none" };
}

function declaredAgainTagged(s: Tagged): Tagged {
	if (s.kind != K.A) return s;
	return { kind: K.B, w: "none" };
}

function words(): string {
	const b = make(1);
	const c = make(2);
	let out = "";
	if (b.kind != "a" && c.kind != "a") {
		const u = id(b);
		const g = u.kind == "b" ? "generic=true," + (u.kind == "b" ? u.w : "") : "generic=false";
		const v = second(b, c);
		const t = v.kind == "c" ? "two=true," + (v.kind == "c" ? v.z : "") : "two=false";
		const list = [b, c];
		const a = "arr=" + (list[0].kind == "b") + "," + (list[1].kind == "c");
		const o = { s: b };
		const n = "anon=" + (o.s.kind == "b");
		const h: { s: Shape } = { s: b };
		const f = "field=" + (h.s.kind == "b");
		const back = declaredAgain(b);
		const r = "back=" + (back.kind == "b") + "," + (back.kind == "b" ? back.w : "");
		out = [g, t, a, n, f, r].join(" ");
	}
	return out;
}

function wordsTagged(): string {
	const b = makeTagged(1);
	const c = makeTagged(2);
	let out = "";
	if (b.kind != K.A && c.kind != K.A) {
		const u = id(b);
		const g = u.kind == K.B ? "generic=true," + (u.kind == K.B ? u.w : "") : "generic=false";
		const v = second(b, c);
		const t = v.kind == K.C ? "two=true," + (v.kind == K.C ? v.z : "") : "two=false";
		const list = [b, c];
		const a = "arr=" + (list[0].kind == K.B) + "," + (list[1].kind == K.C);
		const o = { s: b };
		const n = "anon=" + (o.s.kind == K.B);
		const back = declaredAgainTagged(b);
		const r = "back=" + (back.kind == K.B) + "," + (back.kind == K.B ? back.w : "");
		out = ["enum", g, t, a, n, r].join(" ");
	}
	return out;
}

console.log(words());
console.log(wordsTagged());
