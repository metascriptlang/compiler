// @stdout: 21/x 21/y n42 true 5
// A method with its own type parameter is instantiated with its full binding: the class's
// parameters from the receiver and the method's from the explicit type argument or the arguments.
// Before, the call named the uninstantiated method (C: "call to undeclared function
// Plain_pair_…"), and on a generic class the result type read the class's own T through the
// receiver's binding (`Box<U>` typed as `{ v: int32 }`).

class Plain {
	v: int32;
	constructor(v: int32) { this.v = v; }
	pair<U>(u: U): string { return `${this.v}/${u}`; }
}

class Box<T> {
	v: T;
	constructor(v: T) { this.v = v; }
	map<U>(f: (x: T) => U): Box<U> { return new Box<U>(f(this.v)); }
}

function main(): void {
	const p = new Plain(21 as int32);
	const b = new Box<int32>(21 as int32);
	const s = b.map<string>((x: int32): string => `n${x * 2}`);
	const t = b.map((x: int32): boolean => x > 3);
	const w = new Box<string>("hello").map((x: string): int32 => x.length as int32);
	console.log(`${p.pair<string>("x")} ${p.pair("y")} ${s.v} ${t.v} ${w.v}`);
}
main();
