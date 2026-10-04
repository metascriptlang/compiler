// @stdout: 8 a+++ ab++ 23 a+=z
// note: `x = f(move x)` where f borrows its parameter evaluates the call before the old value of x is destroyed; each case reassigns a class reference from a call that reads it through `move`: an int field over three loop rounds, a string field over three rounds, a nested call, the moved box as a second argument, and a string join beside another box.

class Num {
	n: int32;
	constructor(n: int32) { this.n = n; }
}

class Box {
	s: string;
	constructor(s: string) { this.s = s; }
}

function bump(b: Num): Num { return new Num(b.n + 1); }
function add(a: Num, b: Num): Num { return new Num(a.n + b.n); }
function grow(b: Box): Box { return new Box(b.s + "+"); }
function join(a: Box, b: Box): Box { return new Box(a.s + "=" + b.s); }

function intRounds(): int32 {
	let x = new Num(5);
	for (let i: int32 = 0; i < 3; i += 1) { x = bump(move x); }
	return x.n;
}

function stringRounds(): string {
	let x = new Box("a");
	for (let i: int32 = 0; i < 3; i += 1) { x = grow(move x); }
	return x.s;
}

function nested(): string {
	let x = new Box("ab");
	x = grow(grow(move x));
	return x.s;
}

function secondArgument(): int32 {
	const y = new Num(10);
	let x = new Num(3);
	x = add(y, move x);
	x = add(y, move x);
	return x.n;
}

function joined(): string {
	const z = new Box("z");
	let x = new Box("a");
	x = grow(move x);
	x = join(move x, z);
	return x.s;
}

console.log(`${intRounds()} ${stringRounds()} ${nested()} ${secondArgument()} ${joined()}`);
