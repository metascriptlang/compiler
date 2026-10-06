// @stdout: B 1 A B A | B A
// note: branches that produce a class and its subclass, in either order, join to the class: a conditional, an if/return pair, an array literal, a match and a spawned closure's return; the value keeps its run-time class, so the override answers. Same output on C, JS and the Raiser.
class A { v: int32 = 1; name() { return "A"; } }
class B extends A { name() { return "B"; } }
class C extends A { name() { return "C"; } }

function pickIt(flag: boolean) { return flag ? new B() : new A(); }
function viaIf(flag: boolean) { if (flag) return new B(); return new A(); }
function viaMatch(k: int32) { return match (k) { 0 => new A(), _ => new B() }; }

async function main() {
	const got: A = pickIt(true);
	const other: A = viaIf(false);
	const arr = [new B(), new A()];
	const first: A = arr[0];
	const m: A = viaMatch(0);
	const f = spawn(() => { return true ? new B() : new A(); });
	const g: A = await f;
	const later = true ? new A() : new C();
	console.log(`${got.name()} ${got.v} ${other.name()} ${first.name()} ${m.name()} | ${g.name()} ${later.name()}`);
}
main();
