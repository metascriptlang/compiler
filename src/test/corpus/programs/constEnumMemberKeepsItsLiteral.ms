// @stdout: 11 5 2 true
// @stdout: true false
// @stdout: let widened true
// @stdout: copy widened true
// @stdout: B 7
// @stdout: true true
// @stdout: true

enum Kind { Block, Other, Third }

function keep(): string {
	const c = Kind.Block;
	const d: Kind.Block = c;
	const e = c;
	const f: Kind.Block = e;
	return `${d == Kind.Block} ${f == Kind.Other}`;
}

function letWidens(): string {
	let e = Kind.Block;
	e = Kind.Other;
	return `let widened ${e == Kind.Other}`;
}

function copyWidens(): string {
	const c = Kind.Block;
	let x = c;
	x = Kind.Other;
	return `copy widened ${x == Kind.Other}`;
}

function pick(n: int32): Kind.Block | Kind.Other {
	return n == 1 ? Kind.Block : Kind.Other;
}

function viaMatch(n: int32): string {
	const kl: Kind.Block | Kind.Other = match (n) { 1 => Kind.Block, _ => Kind.Other };
	const direct: Kind.Block | Kind.Other = Kind.Other;
	return `${kl == Kind.Other ? "B" : "A"} ${direct == Kind.Other ? 7 : 0}`;
}

function id<T>(v: T): T { return v; }

function generic(): string {
	const g = id(Kind.Block);
	const h = id(Kind.Block);
	return `${g == Kind.Block} ${h == Kind.Block}`;
}

function label(this kind: Kind): int32 { return (kind as int32) + 10; }

function receiverAndOperators(): string {
	const c = Kind.Other;
	let arm = 0;
	switch (c) { case Kind.Other: arm = 5; break; default: arm = 6; }
	const viaMatch = match (c) { Kind.Block => 1, Kind.Other => 2, Kind.Third => 3 };
	return `${c.label()} ${arm} ${viaMatch} ${c != Kind.Block}`;
}

console.log(receiverAndOperators());
console.log(keep());
console.log(letWidens());
console.log(copyWidens());
console.log(viaMatch(2));
console.log(generic());
console.log(pick(1) == Kind.Block);
