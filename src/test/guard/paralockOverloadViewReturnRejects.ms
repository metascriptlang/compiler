// nim-guard: an overload signature cannot turn a borrowed view into a mutable result.
//
// INVARIANT (PARALOCK E24): when the implementation returns a Readonly<T> view, a
//   signature that declares a view parameter may not declare the mutable T as
//   its return, because the implementation may return that very parameter.
//
// WHAT IT CATCHES: the signature check accepting `pick(a: T, b: Readonly<T>): T`
//   over a view-returning implementation; the pre-fix compiler let a spawned
//   task write the borrowed `shared` through the result and printed 99.
//
// RED MEANS: the signature compiled and the write through the view went unrefused.
//
// GUARD-CHECK-FAIL Overload signature for 'pick' returns the mutable 'T' while its param 2 is the read-only 'Readonly<T>'

class T { n: int32 = 0; }

function pick(a: T, b: Readonly<T>): T;
function pick(a: Readonly<T>, b: Readonly<T>): Readonly<T> {
	return b;
}

const shared = new T();
const f = spawn(() => {
	const mine = new T();
	const leaked = pick(mine, shared); // GUARD-REFUSED
	leaked.n = 99;
	return 0;
});
await f;
console.log(`${shared.n}`);
