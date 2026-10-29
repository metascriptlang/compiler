// @stdout: fn=100 arrow=7 nested=b3
// @exit: 0
// note: a class declared in a function body is a declaration of the module, so its methods and constructor carry one set of counts: a returned reference argument and a field initializer each hold one count.

class Box { v: int32 = 100; }

function inFunction(): int32 {
	class Holder { b: Box = new Box(); pass(b: Box): Box { return b; } }
	const h = new Holder();
	return h.pass(h.b).v;
}

const inArrow = (): int32 => {
	class Counter {
		box: Box;
		constructor(start: int32) { this.box = new Box(); this.box.v = start; }
		keep(b: Box): Box { return b; }
	}
	const c = new Counter(7);
	return c.keep(c.box).v;
};

function nested(): string {
	const inner = (): string => {
		class Tag { name: string; constructor(n: int32) { this.name = "b" + n.toString(); } read(): string { return this.name; } }
		return new Tag(3).read();
	};
	return inner();
}

console.log(`fn=${inFunction()} arrow=${inArrow()} nested=${nested()}`);
