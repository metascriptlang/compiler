// @stdout: 42 3 gau 1 true true false ok
// The C backend used to bind method calls to the receiver's STATIC type:
// `const b: Base = new Derived(); b.step(3)` ran Base.step (printed 0) while
// the JS backend ran Derived.step (42) — one program, two meanings. Method
// calls on overridden instance methods now route through a msIsInstance
// if-chain dispatcher (Nim cgmeth genIfDispatcher analog): the runtime type
// decides, most-derived override wins, `this`-calls inside a base method
// dispatch too, inherited methods resolve through the base chain, and
// `instanceof` reads the msTypeInfo.base chain on C.

class Base { step(n: number): number { return 0; } }
class Derived extends Base { step(n: number): number { return 42; } }

class L1 { step(): number { return 1; } }
class L2 extends L1 { step(): number { return 2; } }
class L3 extends L2 { step(): number { return 3; } }

class Animal {
	speak(): string { return "..."; }
	describe(): string { return this.speak(); }
}
class Dog extends Animal { speak(): string { return "gau"; } }

class HasOnly { foo(): number { return 1; } }
class Sub extends HasOnly { z: number = 0; }

function main() {
	const b: Base = new Derived();
	const v: L1 = new L3();
	const a: Animal = new Dog();
	const s = new Sub();
	const parts: string[] = [];
	parts.push(b.step(3).toString());
	parts.push(v.step().toString());
	parts.push(a.describe());
	parts.push(s.foo().toString());
	parts.push((b instanceof Derived).toString());
	parts.push((b instanceof Base).toString());
	parts.push((a instanceof L1).toString());
	console.log(parts.join(" ") + " ok");
}
main();
