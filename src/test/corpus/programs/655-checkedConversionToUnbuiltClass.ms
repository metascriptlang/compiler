// @stdout: unbuilt iof-unknown=false iof-base=false as-unknown=ok as-base=ok
// @xfail(raiser): the Raiser VM cannot evaluate class inheritance (super) or instanceof at comptime

class A { a: int32 = 1; }
class B { b: string = "b"; }
class Base { id: int32 = 0; }
class Derived extends Base { extra: int32 = 2; }

function main(): void {
	const u: unknown = new A();
	const x: Base = new Base();
	const none: unknown | null = null;
	const noBase: Base | null = null;
	const b = none as B | null;
	const d = noBase as Derived | null;
	console.log(`unbuilt iof-unknown=${u instanceof B} iof-base=${x instanceof Derived} as-unknown=${b == null ? "ok" : "bad"} as-base=${d == null ? "ok" : "bad"}`);
}
main();
