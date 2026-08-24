// @stdout: span-decl all-ok
// A Span-typed declaration must coerce its initializer exactly like a call
// argument does: `const s: Span<T> = arr` used to emit a raw C assign
// `msSpan = msUint8Array*` because only call sites were wrapped.

function describe(s: Span<uint8>): string {
	return s.length.toString() + ":" + s[0].toString();
}

let fails = 0;

function check(label: string, got: string, want: string): void {
	if (got !== want) {
		fails = fails + 1;
		console.log(label + " got " + got + " want " + want);
	}
}

const heap: uint8[] = [7, 8, 9];
const sHeap: Span<uint8> = heap;
check("heap", describe(sHeap), "3:7");

const sized: uint8[4] = [1, 2, 3, 4];
const sSized: Span<uint8> = sized;
check("sized", describe(sSized), "4:1");

const sLit: Span<uint8> = [5, 6];
check("lit", describe(sLit), "2:5");

let sLet: Span<uint8> = heap;
check("let", describe(sLet), "3:7");
sLet = sized;
check("let-reassign", describe(sLet), "4:1");

if (fails === 0) {
	console.log("span-decl all-ok");
}
