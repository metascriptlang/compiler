// nim-guard: narrowing a read-only union keeps the view on the member it picks.
//
// INVARIANT (PARALOCK E24): Readonly<A | B> is Readonly<A> | Readonly<B>, so a
//   `!= null`, `instanceof` or `typeof` test on a view hands back a view, and a
//   spawned task that borrows `shared` cannot write through a field it narrowed.
//
// WHAT IT CATCHES: the union view keeping its members mutable; the pre-fix
//   compiler let the task below write all three fields of the borrowed `shared`.
//
// RED MEANS: one of the three writes through a narrowed view compiled.
//
// GUARD-CHECK-FAIL cannot write through Readonly<T>
// GUARD-CHECK-FAIL cannot write through Readonly<A>
// GUARD-CHECK-FAIL cannot write through Readonly<C>

class A { n: int32 = 0; }
class B { m: int32 = 0; }
class C { n: int32 = 0; }
class T {
	n: int32 = 0;
	k: T | null = null;
	ab: A | B = new A();
	sa: string | C = "x";
}

const shared = new T();
shared.k = new T();
shared.sa = new C();
const f = spawn(() => {
	const k = shared.k;
	if (k != null) k.n = 99; // GUARD-REFUSED
	const ab = shared.ab;
	if (ab instanceof A) ab.n = 98; // GUARD-REFUSED
	const sa = shared.sa;
	if (typeof sa != "string") sa.n = 97; // GUARD-REFUSED
	return 0;
});
await f;
