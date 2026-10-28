// @stdout: 1 1 int 5 int 6
// @stdout: 2 1 str k int 8
// @stdout: 3 3 int 9 int 5
// @stdout: 3 3 str z int 5
struct Pair { x: int32; y: int32; }

function label(v: int32 | string): string {
	if (typeof v == "string") return "str " + v;
	return "int " + v.toString();
}

class A {
	make(k: int32 | string): Pair { return { x: 1, y: 1 }; }
	pick(n: int32): int32 | string { return n + 1; }
	describe(k: int32 | string, n: int32): string {
		const p = this.make(k);
		return `${p.x} ${p.y} ${label(k)} ${label(this.pick(n))}`;
	}
}
class B extends A {
	make(k: int32 | string): Pair { return { x: 2, y: 1 }; }
	pick(n: int32): int32 { return n + 3; }
}
class C extends B {
	make(k: int32 | string): Pair { return { x: 3, y: 3 }; }
	pick(n: int32): int32 { return n; }
}

const items: A[] = [new A(), new B(), new C(), new C()];
const args: (int32 | string)[] = [5, "k", 9, "z"];
for (let i = 0; i < items.length; i += 1) console.log(items[i].describe(args[i], 5));
