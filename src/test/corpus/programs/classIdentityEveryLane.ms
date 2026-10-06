// @stdout: chain=TTFF/TTTF null=FT unknown=F3 kinds=ABCD pick=B2,other,other caught=TT,FT spawned=TT
// note: an object keeps the class it was made with: instanceof answers by it and by the classes it derives from, a checked `as` passes on it, null tests false, an `unknown` holding a generic instance converts back to that instance, a caught exception tests by its class, and an object made in a spawned strand keeps its class after the await. Before, the Raiser kept no class on an object and stopped at the first instanceof.
class A { a: int32 = 1; }
class B extends A { b: int32 = 2; }
class C extends B { }
class D extends A { }
class Box<T> { v: T; constructor(v: T) { this.v = v; } }
class MyErr extends Error { code: int32 = 7; }
function tf(v: boolean): string { return v ? "T" : "F"; }
const x: A = new B();
const c: A = new C();
const d: A = new D();
const chain = tf(x instanceof B) + tf(x instanceof A) + tf(x instanceof C) + tf(x instanceof D) + "/"
	+ tf(c instanceof A) + tf(c instanceof B) + tf(c instanceof C) + tf(d instanceof B);
const n: A | null = null;
const maybe: A | null = new C();
const u: unknown = new Box<int32>(3);
const all: A[] = [new A(), new B(), new C(), new D()];
let kinds = "";
for (const e of all) kinds = kinds + (e instanceof C ? "C" : e instanceof B ? "B" : e instanceof D ? "D" : "A");
function pick(h: unknown): string {
	if (h instanceof B) return "B" + h.b.toString();
	return "other";
}
function fail(k: int32): void {
	if (k == 1) throw new MyErr("mine");
	throw new Error("plain");
}
let caught = "";
for (let k = 1; k <= 2; k += 1) {
	try { fail(k); } catch (e) { caught = caught + (caught == "" ? "" : ",") + tf(e instanceof MyErr) + tf(e instanceof Error); }
}
async function spawned(): Promise<string> {
	const f = spawn((): A => new C());
	const got: A = await f;
	return tf(got instanceof B) + tf(got instanceof C);
}
const s = await spawned();
console.log("chain=" + chain + " null=" + tf(n instanceof A) + tf(maybe instanceof B) + " unknown=" + tf(u instanceof A) + (u as Box<int32>).v.toString()
	+ " kinds=" + kinds + " pick=" + pick(new C()) + "," + pick(new D()) + "," + pick(new Box<string>("s")) + " caught=" + caught + " spawned=" + s);
