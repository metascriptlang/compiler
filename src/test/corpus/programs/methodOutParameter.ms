// @stdout: 6 4 hi 9 7
// note: a class method takes `out` and `ref` parameters like a function: the callee writes the caller's variable in place, for a plain class and for a generic class instance, and a method may pass its own out parameter on.

class Box {
	fill(out x: int32, n: int32): void {
		x = n + 5;
	}
	bump(ref x: int32): void {
		x += 1;
	}
	forward(out x: int32): void {
		this.fill(out x, 2);
	}
}

class Slot<T> {
	put(out x: T, v: T): void {
		x = v;
	}
}

let a: int32;
new Box().fill(out a, 1);
let b: int32 = 3;
new Box().bump(b);
let s: string;
new Slot<string>().put(out s, "hi");
let z: int32;
new Slot<int32>().put(out z, 9);
let f: int32;
new Box().forward(out f);
console.log(a, b, s, z, f);
