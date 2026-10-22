import { compileToCWithStd } from "../helpers";

test "raiserObjectTemplate: a class declared inside a @comptime call and its subclass build objects at compile time" {
	const c = compileToCWithStd(`@comptime function build(n: int32): int32 {
	class A { x: int32 = 1; name: string = ''; u: int32 | string | null = null; }
	class B extends A { y: int32 = 2; }
	const b = new B(); b.y = n; b.u = 'k';
	const a = new A(); a.x = 40;
	return a.x + b.x + b.y + a.name.length + (a.u == null ? 100 : 0);
}
const k = build(5);
console.log(k);`);
	assert c.ok, c.error;
	assert c.value.includes("146"), "the comptime result folds into the program";
}

test "raiserObjectTemplate: a second @comptime call appended to the live image lays its own class" {
	const c = compileToCWithStd(`class T { a: int32 = 3; s: string = 'z'; }
@comptime function first(): int32 { const t = new T(); t.a = 4; return t.a + t.s.length; }
@comptime function second(): int32 { class U { w: int32 = 7; f: float64 = 0.5; } const u = new U(); return u.w + (u.f > 0.4 ? 1 : 0); }
console.log(first() * 100 + second());`);
	assert c.ok, c.error;
	assert c.value.includes("508"), "both results fold";
}
