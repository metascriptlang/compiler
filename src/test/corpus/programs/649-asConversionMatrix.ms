// @stdout: as-conv center center stretch,null center,null center center 4 auto s:auto,null n:4,null s:stretch center auto s:center,null s:auto stretch 5/6/8 5/6 7/1.5

type Align = "auto" | "center" | "stretch";
type Wire = number | string | null;

function show(a: Align | null): string {
	if (a == null) return "null";
	const t: string = a;
	return t;
}

function wshow(w: Wire): string {
	if (w == null) return "null";
	if (typeof w === "number") {
		const n: number = w;
		return `n:${n}`;
	}
	if (typeof w === "string") {
		const s: string = w;
		return `s:${s}`;
	}
	return "?";
}

function strToLit(s: string): Align { return s as Align; }
function strToLitN(s: string): Align | null { return s as Align | null; }
function strNToLitN(s: string | null): Align | null { return s as Align | null; }
function wireToLitN(v: Wire): Align | null { return v as Align | null; }
function wireToLit(v: Wire): Align { return v as Align; }
function wireToStr(v: Wire): string { return v as string; }
function wireToNumN(v: Wire): number | null { return v as number | null; }
function litToStr(a: Align): string { return a as string; }
function litNToWire(a: Align | null): Wire { return a as Wire; }
function numNToWire(n: number | null): Wire { return n as Wire; }
function litToWire(a: Align): Wire { return a as Wire; }
function unionToStr(u: number | string): string { return u as string; }
function unionToLit(u: number | string): Align { return u as Align; }
function unionToLitN(u: number | string): Align | null { return u as Align | null; }
function assignLitN(a: Align | null): Wire { const w: Wire = a; return w; }
function assignLit(a: Align): number | string { const u: number | string = a; return u; }

struct Left { a: int32 }
struct Right { b: int32 }
type Pair = Left | Right;
type Amount = int32 | float64;

function pairLeft(): Pair { const l: Left = { a: 5 }; return l; }
function pairRight(): Pair { const r: Right = { b: 6 }; return r; }
function pairLit(): Pair { const p: Pair = { b: 8 }; return p; }
function pairLeftOf(p: Pair): int32 { const l = p as Left; return l.a; }
function pairRightOf(p: Pair): int32 { const r = p as Right; return r.b; }
function amountOf(whole: boolean): Amount { if (whole) return 7; return 1.5; }
function pairAfter(): string {
	const list: Pair[] = [];
	list.push(pairLeft());
	list.push(pairRight());
	return `${pairLeftOf(list[0])}/${pairRightOf(list[1])}`;
}

function main(): void {
	const w: Wire = "center";
	const z: Wire = null;
	const k: Wire = 4;
	const nn: number | null = null;
	const nw = wireToNumN(k);
	const nwText = nw == null ? "null" : `${nw}`;
	console.log("as-conv " + [
		show(strToLit("center")),
		show(strToLitN("center")),
		show(strNToLitN("stretch")) + "," + show(strNToLitN(null)),
		show(wireToLitN(w)) + "," + show(wireToLitN(z)),
		show(wireToLit(w)),
		wireToStr(w),
		nwText,
		litToStr("auto"),
		wshow(litNToWire("auto")) + "," + wshow(litNToWire(null)),
		wshow(numNToWire(4)) + "," + wshow(numNToWire(nn)),
		wshow(litToWire("stretch")),
		unionToStr("center"),
		show(unionToLit("auto")),
		wshow(assignLitN("center")) + "," + wshow(assignLitN(null)),
		wshow(assignLit("auto")),
		show(unionToLitN("stretch")),
		`${pairLeftOf(pairLeft())}/${pairRightOf(pairRight())}/${pairRightOf(pairLit())}`,
		pairAfter(),
		`${amountOf(true) as int32}/${amountOf(false) as float64}`,
	].join(" "));
}
main();
