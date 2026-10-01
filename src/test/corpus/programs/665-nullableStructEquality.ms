// @xfail(raiser): struct == compares by reference on raiser (card 2026-09-29-raiser-struct-equality-by-reference)
// @stdout: some=true,false none=true,false,false neq=false,true payload=true,false,false call=true,2 int=true,true
// note: `==` between two `S | null` values, or an `S | null` and an `S`, compares the payloads field by field when both are present and is true when both are absent; a call operand runs once; a nullable primitive compares by value. Same output on every backend.

struct In { a: int32; s: string; }

let calls: int32 = 0;

function make(a: int32): In | null {
	calls = calls + 1;
	return { a: a, s: "k" };
}

function main(): void {
	const p: In | null = { a: 2, s: "x" };
	const q: In | null = { a: 2, s: "x" };
	const r: In | null = { a: 3, s: "x" };
	const n1: In | null = null;
	const n2: In | null = null;
	const plain: In = { a: 2, s: "x" };
	const i1: int32 | null = 5;
	const i2: int32 | null = 5;
	const once = make(1) == make(1);
	console.log(`some=${p == q},${p == r} none=${n1 == n2},${p == n1},${n1 == p}`
		+ ` neq=${p != q},${p != r} payload=${p == plain},${r == plain},${n1 == plain}`
		+ ` call=${once},${calls} int=${i1 == i2},${i1 == 5}`);
}

main();
