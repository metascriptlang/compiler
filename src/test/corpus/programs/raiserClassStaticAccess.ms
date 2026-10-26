// @stdout: 7 9 16 8
// @stdout: hi! 3 2
// @stdout: sub 5 base 5
// @stdout: 12 13 3
// note: a class static is one global read and written from other functions, through compound assignment and update, as a literal, a string, an array and a subclass access; the Raiser keeps one slot per static field symbol
class Counter {
	static n: int32 = 7;
	static label: string = "hi";
	static items: int32[] = [1, 2];
	static bump(by: int32): int32 { Counter.n += by; return Counter.n; }
}

class Base {
	static shared: int32 = 5;
}

class Sub extends Base {
	static own: string = "sub";
}

function readN(): int32 { return Counter.n; }
function writeN(v: int32): void { Counter.n = v; }
function grow(): void { Counter.items.push(3); Counter.label += "!"; }

const before = readN();
writeN(9);
const after = Counter.n;
const bumped = Counter.bump(7);
Counter.n--;
console.log(before, after, bumped, Counter.n - 7);
grow();
console.log(Counter.label, Counter.items.length, Counter.items[1]);
Base.shared = 5;
console.log(Sub.own, Sub.shared, "base", Base.shared);
Counter.n = 12;
Counter.n++;
let copy = Counter.items;
copy = [4];
console.log(Counter.n - 1, Counter.n, Counter.items.length);
