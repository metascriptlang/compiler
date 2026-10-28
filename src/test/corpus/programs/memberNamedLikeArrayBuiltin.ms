// Parity program — a user member named `push`, `setLength` or `toString` is the user's member on
// every backend: an array builtin is recognised by the std symbol a call resolves to, never by the
// member's spelling. Axes: a function-typed interface field named `push` and `setLength`, a class
// method for each of the three names, and the std builtins beside them (array push and setLength,
// number and array toString).
//
// @stdout: 101 42
// @stdout: 1 0 stack:1
// @stdout: 2 1 3.5 1
// @exit: 0

interface Bag {
	push: (v: int32) => int32;
	setLength: (n: int32) => int32;
}

class Stack {
	items: int32[] = [];
	push(v: int32): int32 {
		this.items.push(v);
		return this.items.length;
	}
	setLength(n: int32): int32 {
		this.items.setLength(n);
		return this.items.length;
	}
	toString(): string {
		return `stack:${this.items.length}`;
	}
}

const bag: Bag = {
	push: (v: int32): int32 => v + 100,
	setLength: (n: int32): int32 => n * 2,
};
console.log(`${bag.push(1)} ${bag.setLength(21)}`);

const stack = new Stack();
const pushed = stack.push(5);
const cut = stack.setLength(0);
stack.push(6);
console.log(`${pushed} ${cut} ${stack.toString()}`);

const xs: int32[] = [1];
xs.push(2);
const len = xs.length;
xs.setLength(1);
console.log(`${len} ${xs.length} ${(3.5).toString()} ${xs.toString()}`);
