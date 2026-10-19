// @stdout: 1 40 set2 Stack(1)
// @stdout: 2 5 Pair(2)
// @stdout: sized 3
// @stdout: 3 9 2 7 3 5 abc
// note: a class or interface member spelled like an array or string builtin (length, push, setLength, toString) is that member on every backend; real arrays and strings keep the builtin.
class Stack {
	items: int32[] = [];
	length: int32 = 0;
	push(v: int32): void { this.items.push(v * 10); this.length += 1; }
	setLength(n: int32): string { return "set" + n; }
	toString(): string { return "Stack(" + this.length + ")"; }
}

class Pair<T> {
	held: T[] = [];
	length: int32 = 0;
	push(v: T): int32 { this.held.push(v); this.length += 1; return this.length; }
	toString(): string { return "Pair(" + this.length + ")"; }
}

interface Sized {
	length: int32;
}

function sizeOf(s: Sized): int32 {
	return s.length;
}

const s = new Stack();
s.push(4);
console.log(s.length, s.items[0], s.setLength(2), s.toString());
const p = new Pair<string>();
p.push("a");
console.log(p.push("b"), p.held.length + 3, p.toString());
console.log("sized", sizeOf({ length: 3 }));
const arr: int32[] = [1, 2];
arr.push(9);
const text = "abcde";
arr.setLength(2);
console.log(3, 9, arr.length, (7).toString(), [3].toString(), text.length, text.substring(0, 3));
