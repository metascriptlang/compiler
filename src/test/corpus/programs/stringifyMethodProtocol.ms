// @stdout: explicit=$7 base=1/2 sub=sub:1 num=5 flag=true joined=$7-5

class Money {
	amount: number;
	constructor(a: number) { this.amount = a; }
	toString(): string { return "$" + this.amount.toString(); }
}

class Pair {
	a: number;
	b: number;
	constructor(a: number, b: number) { this.a = a; this.b = b; }
	toString(): string { return this.a.toString() + "/" + this.b.toString(); }
}

class Sub extends Pair {
	constructor(a: number) { super(a, 0); }
	toString(): string { return "sub:" + this.a.toString(); }
}

function main(): void {
	const m = new Money(7);
	const p = new Pair(1, 2);
	const s = new Sub(1);
	const n = 5;
	const flag = true;
	console.log(`explicit=${m.toString()} base=${p.toString()} sub=${s.toString()} num=${n.toString()} flag=${flag.toString()} joined=${m}-${n}`);
}

main();
