// @stdout: one 3
// @stdout: none
// @stdout: deep 3 4
// @stdout: big 6
// @stdout: three 7
struct Big { a: int64; b: int64; c: int64; d: int64; e: int64; }

class A {
	one(x: int32, y: int32): void { console.log("A"); }
	none(x: int32): void { console.log("A"); }
	deep(x: int32, y: int32, z: int32): void { console.log("A"); }
	big(w: Big, k: int32): void { console.log("A"); }
	three(x: int32, y: int32, z: int32): int32 { return 0; }
}
class B extends A {
	one(x: int32): void { console.log(`one ${x}`); }
	none(): void { console.log("none"); }
	deep(x: int32, y: int32): void { console.log(`deep ${x} ${y}`); }
	big(w: Big): void { console.log(`big ${w.a + w.b + w.c}`); }
	three(x: int32): int32 { return x + 4; }
}
class C extends B {
	deep(x: int32): void { console.log(`deep ${x} 4`); }
}

const a: A = new B();
a.one(3, 4);
a.none(1);
const c: A = new C();
c.deep(3, 4, 5);
a.big({ a: 1, b: 2, c: 3, d: 4, e: 5 }, 9);
console.log(`three ${a.three(3, 4, 5)}`);
