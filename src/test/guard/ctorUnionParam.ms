// A constructor argument is fitted to its parameter like any call argument:
// a member widens into a union parameter, and the `_init` prototype takes
// the parameter the way the definition does. Nim: constructor arguments go
// through sigmatch like every call. RED MEANS the `new` path stopped fitting
// its arguments or prototypes `_init` on its own — run /trace-nim on Holder.
// GUARD-JS

type A = { x: int32 };
type B = { y: int32 };
type C = { z: string };

class Two { data: A | B; constructor(d: A | B) { this.data = d; } set(d: A | B): void { this.data = d; } }
class Three { data: A | B | C; constructor(d: A | B | C) { this.data = d; } }
class Prim { data: int32 | string; constructor(d: int32 | string) { this.data = d; } }

let failures = 0;
function expect(label: string, ok: boolean): void {
	if (!ok) { console.log("FAIL " + label); failures += 1; }
}

function main(): void {
	const two = new Two({ x: 1 });
	expect("two members", (two.data as A).x == 1);
	two.set({ y: 2 });
	expect("method union param", (two.data as B).y == 2);
	const three = new Three({ z: "c" });
	expect("three members", (three.data as C).z == "c");
	const prim = new Prim(4);
	expect("primitive union", (prim.data as int32) == 4);
	const primS = new Prim("s");
	expect("primitive union string", (primS.data as string) == "s");
}
main();
if (failures == 0) console.log("GUARD-OK");
