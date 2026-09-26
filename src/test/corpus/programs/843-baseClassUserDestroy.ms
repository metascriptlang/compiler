// @xfail(raiser): raiser runtime error: cannot evaluate 'super' at comptime: symbol kind is Class
// @skip-js: C-only by design: user lifecycle hooks run where the DRC runs; JS has no destructors
class Animal {
	h: int32;
	constructor(h: int32) { this.h = h; }
	onDestroy(): void { console.log("animal destroy " + this.h.toString()); }
}

class Dog extends Animal {
	bark: string;
	constructor(h: int32, b: string) { super(h); this.bark = b; }
}

class Puppy extends Dog {
	toy: string;
	constructor(h: int32, b: string, t: string) { super(h, b); this.toy = t; }
}

function run(): void {
	const a = new Animal(1);
	const d = new Dog(2, "wo" + "of");
	const p = new Puppy(3, "yi" + "p", "ba" + "ll");
	console.log(a.h.toString() + " " + d.bark + " " + p.toy);
}
run();
console.log("done");
