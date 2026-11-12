import { hasErrors } from "../../checker/context";
import { ctorRoutineOf } from "../../checker/ctorRoutine";
import { lookupSymbol } from "../../checker/symbol";
import { checkSource } from "./helpers";

const SUNK_PRELUDE = `
class P { name: string; constructor(name: string) { this.name = name; } }
interface Box { item: P; }
const held: P[] = [];
let last: P | null = null;
function keep(sink x: P): void { held.push(x); }
function look(x: P): int32 { return x.name.length; }
class Kid { up: Unowned<P> | null; constructor(up: P) { this.up = up; } }
class Holder { item: P; constructor(item: P) { this.item = item; } }
`;

// The parameters the constructor of `name` takes, with the first user parameter as bit 0;
// -1 when the source has errors, -2 when the bits never settled.
function takenBy(classDecl: string, name: string): int32 {
	const ctx = checkSource(SUNK_PRELUDE + classDecl);
	if (hasErrors(ctx)) return -1;
	const routine = ctorRoutineOf(lookupSymbol(ctx.table, name));
	if (routine == null || (routine.sunkParams & 1) == 0) return -2;
	return routine.sunkParams >> 1;
}

test "ctorSunkParams: a constructor takes the parameters its body moves into an owning place" {
	assert takenBy("", "Holder") == 1;
	assert takenBy("class Two { a: P; b: P; constructor(a: P, n: int32, b: P) { this.a = a; this.b = b; } }", "Two") == 5;
	assert takenBy("class Pushes { all: P[] = []; constructor(p: P) { this.all.push(p); } }", "Pushes") == 1;
	assert takenBy("class Sinks { constructor(p: P) { keep(p); } }", "Sinks") == 1;
	assert takenBy("class Global { constructor(p: P) { last = p; } }", "Global") == 1;
	assert takenBy("class Arr { all: P[]; constructor(p: P) { this.all = [p]; } }", "Arr") == 1;
	assert takenBy("class Lit { box: Box; constructor(p: P) { this.box = { item: p }; } }", "Lit") == 1;
	assert takenBy("class Both { own: P; up: Unowned<P> | null; constructor(p: P) { this.own = p; this.up = p; } }", "Both") == 1;
	assert takenBy("class Prop { constructor(n: int32, readonly item: P) {} }", "Prop") == 2;
	assert takenBy("class Moves { own: P | null = null; constructor(p: P, on: boolean) { if (on) this.own = move p; } }", "Moves") == 1;
	assert takenBy("class Gen<T> { v: T; constructor(v: T) { this.v = v; } }", "Gen") == 1;
}

test "ctorSunkParams: a constructor lends the parameters it reads, keeps Unowned or stores under a condition" {
	assert takenBy("", "Kid") == 0;
	assert takenBy("class Reads { n: int32; constructor(p: P) { this.n = look(p); } }", "Reads") == 0;
	assert takenBy("class Ups { ups: Unowned<P>[] = []; constructor(p: P) { this.ups.push(p); } }", "Ups") == 0;
	assert takenBy("class Maybe { own: P | null = null; constructor(p: P, on: boolean) { if (on) this.own = p; } }", "Maybe") == 0;
	assert takenBy("class Either { own: P | null; constructor(p: P, on: boolean) { this.own = on ? p : null; } }", "Either") == 0;
	assert takenBy("class Loop { all: P[] = []; constructor(p: P, n: int32) { for (let i = 0; i < n; i++) this.all.push(p); } }", "Loop") == 0;
	assert takenBy("class Late { own: P | null = null; constructor(p: P, skip: boolean) { if (skip) return; this.own = p; } }", "Late") == 0;
	assert takenBy("class Local { n: int32; constructor(p: P) { let q = p; q = p; this.n = q.name.length; } }", "Local") == 0;
}

test "ctorSunkParams: a constructor lends a parameter it stores after something that can leave the constructor" {
	assert takenBy("class Guard { own: P; constructor(p: P, on: boolean) { if (on) throw new Error(\"x\"); this.own = p; } }", "Guard") == 0;
	assert takenBy("class Calls { n: int32; own: P; constructor(p: P, q: P) { this.n = look(q); this.own = p; } }", "Calls") == 0;
	assert takenBy("class News { h: Holder; own: P; constructor(p: P, q: P) { this.h = new Holder(q); this.own = p; } }", "News") == 2;
	assert takenBy("class Init { n: int32 = look(new P(\"x\")); own: P; constructor(p: P) { this.own = p; } }", "Init") == 0;
	assert takenBy("class PropSub extends Holder { constructor(readonly own: P, q: P) { super(q); } }", "PropSub") == 2;
	assert takenBy("class G { get v(): int32 { return 1; } }\nclass Reads { n: int32; own: P; constructor(p: P, g: G) { this.n = g.v; this.own = p; } }", "Reads") == 0;
	assert takenBy("class Iter { own: P; constructor(p: P, xs: int32[]) { for (const x of xs) {} this.own = p; } }", "Iter") == 0;
}

test "ctorSunkParams: a parameter handed to another constructor is taken when that constructor keeps it" {
	assert takenBy("class Owner { h: Holder; constructor(p: P) { this.h = new Holder(p); } }", "Owner") == 1;
	assert takenBy("class Wrap { kid: Kid; constructor(p: P) { this.kid = new Kid(p); } }", "Wrap") == 0;
	assert takenBy("class Sub extends Holder { constructor(p: P) { super(p); } }", "Sub") == 1;
	assert takenBy("class Sub extends Holder { constructor(p: P) { super(p); } }\nclass Deep extends Sub { constructor(n: int32, p: P) { super(p); } }", "Deep") == 2;
	assert takenBy("class Early { h: Late; constructor(p: P) { this.h = new Late(p); } }\nclass Late { item: P; constructor(item: P) { this.item = item; } }", "Early") == 1;
	assert takenBy("class Gen<T> { v: T; constructor(v: T) { this.v = v; } }\nclass GenSub<T> extends Gen<T> { constructor(v: T) { super(v); } }", "GenSub") == 1;
	assert takenBy("class Cond { h: Holder | null = null; constructor(p: P, on: boolean) { if (on) this.h = new Holder(p); } }", "Cond") == 0;
}

test "ctorSunkParams: constructors that hand a parameter to each other take it only when one of them keeps it" {
	const ring = "class A { b: B; constructor(p: P) { this.b = new B(p); } }\nclass B { a: A; constructor(p: P) { this.a = new A(p); } }";
	assert takenBy(ring, "A") == 0;
	assert takenBy(ring, "B") == 0;
	const kept = "class A { b: B; constructor(p: P) { this.b = new B(p); } }\nclass B { a: A; own: P; constructor(p: P) { this.own = p; this.a = new A(p); } }";
	assert takenBy(kept, "A") == 1;
	assert takenBy(kept, "B") == 1;
}
