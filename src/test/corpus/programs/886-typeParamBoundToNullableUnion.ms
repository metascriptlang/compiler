// @stdout: struct=set string=set second=2 undef=set classes=B pair=a:set,b:null

// A value of `X` passed for `T` after another argument bound `T` to `X | null`
// (and the reverse order) infers `T = X | null`, as the supertype of the candidates.
class Box<T> {
	value: T;
	constructor(value: T) { this.value = value; }
}
struct Ev { url: string; }
struct A { a: string; }
struct B { b: string; }

function put<T>(box: Box<T>, value: T): void { box.value = value; }
function push2<T>(value: T, xs: T[]): void { xs.push(value); }
function pickLast<T>(a: T, b: T): T { return b; }

const evBox = new Box<Ev | null>(null);
const ev: Ev = { url: "/a" };
put(evBox, ev);
const e = evBox.value;
const struct = e === null ? "null" : "set";

const sBox = new Box<string | null>(null);
put(sBox, "a");
const str = sBox.value === null ? "null" : "set";

const xs: (Ev | null)[] = [null];
push2(ev, xs);

const uBox = new Box<Ev | undefined>(undefined);
put(uBox, ev);
const undef = uBox.value === undefined ? "none" : "set";

const abBox = new Box<A | B>({ a: "x" });
const b: B = { b: "y" };
put(abBox, b);
const picked = pickLast<A | B>({ a: "x" }, b);
const classes = "b" in picked ? "B" : "A";

const maybe: Ev | null = null;
const last = pickLast(maybe, ev);
const first = pickLast(ev, maybe);
const pair = (last === null ? "a:null" : "a:set") + "," + (first === null ? "b:null" : "b:set");

console.log(`struct=${struct} string=${str} second=${xs.length} undef=${undef} classes=${classes} pair=${pair}`);
