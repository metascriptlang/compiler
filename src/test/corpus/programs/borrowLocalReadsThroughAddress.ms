// @stdout: card=3/2 scalar=8/true/7 text=5/hello!/true struct=6/10 class=5 field=5/12 element=3 param=16 generic=4/x copy=7 alias=9/7 temp=5/8/4 nested=2
// note: a Borrow<T> local holds the address of the variable, field or element it was taken from, and every read goes through that address on every backend; a change made through an alias or a callee is seen by the next read.

struct Big { a: int32; b: int32; c: int64; d: int64; e: int64 }
class Counter { v: int32 = 5; }
struct Bag { items: int32[]; big: Big; }

function viaGeneric<T>(v: T): T {
	const b: Borrow<T> = v;
	return b;
}

function fromParams(xs: int32[], big: Big): int32 {
	const b: Borrow<int32[]> = xs;
	const e: Borrow<Big> = big;
	return b[2] + e.b + e.a;
}

function poke(a: int32[]): void { a[0] = 9; }
function setV(c: Counter): void { c.v = 8; }

function seenThroughAliases(): string {
	const xs: int32[] = [1, 2];
	const b: Borrow<int32> = xs[0];
	poke(xs);
	const counter = new Counter();
	const c: Borrow<int32> = counter.v;
	setV(counter);
	const other = counter;
	other.v = 7;
	return `${b}/${c}`;
}

function make(): Big { return { a: 4, b: 5, c: 6, d: 7, e: 8 }; }
function readA(b: Borrow<Big>): int32 { return b.a + 1; }
function readN(b: Borrow<int32>): int32 { return b + 1; }
function seven(): int32 { return 7; }

function viewOfView(): int32 {
	const xs = [1, 2, 3];
	const b: Borrow<int32[]> = xs;
	const again: Borrow<int32> = b[1];
	return again;
}

const out: string[] = [];
const xs = [1, 2, 3];
const card: Borrow<int32[]> = xs;
out.push(`card=${card.length}/${card[1]}`);

const n: int32 = 7;
const bn: Borrow<int32> = n;
out.push(`scalar=${bn + 1}/${bn == 7}/${bn}`);

const s = "hello";
const bs: Borrow<string> = s;
out.push(`text=${bs.length}/${bs + "!"}/${bs == "hello"}`);

const bigs: Big[] = [{ a: 1, b: 2, c: 3, d: 4, e: 5 }, { a: 6, b: 7, c: 8, d: 9, e: 10 }];
const be: Borrow<Big> = bigs[1];
out.push(`struct=${be.a}/${be.e}`);

const counter = new Counter();
const bc: Borrow<Counter> = counter;
out.push(`class=${bc.v}`);

const bag: Bag = { items: [4, 5], big: { a: 11, b: 12, c: 0, d: 0, e: 0 } };
const bf: Borrow<int32[]> = bag.items;
const bg: Borrow<Big> = bag.big;
out.push(`field=${bf[1]}/${bg.b}`);

const element: Borrow<int32> = xs[2];
out.push(`element=${element}`);
out.push(`param=${fromParams(xs, bigs[1])}`);
out.push(`generic=${viaGeneric<int32>(4)}/${viaGeneric<string>("x")}`);

const copy = be;
out.push(`copy=${copy.b}`);
out.push(`alias=${seenThroughAliases()}`);
out.push(`temp=${readA(make())}/${readN(seven())}/${readN(3)}`);
out.push(`nested=${viewOfView()}`);
console.log(out.join(" "));
