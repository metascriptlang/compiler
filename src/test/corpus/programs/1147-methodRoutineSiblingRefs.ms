// @stdout: sibling=5 param=10 ctor=6 plain=7
// note: a nested `const` arrow inside a method or a constructor that closes over `this` or a parameter, called from a sibling arrow or one level deeper, is a routine with a recorded env on the raiser VM as it is on C. The raiser lowering keeps methods in their class, so the method body must set up the shared env a function body gets.

class Box {
	n: int32 = 3;

	constructor(seed: int32) {
		this.n = seed;
		const read = (): int32 => { return this.n; };
		const bump = (): int32 => { return read() + 1; };
		this.n = bump();
	}

	sibling(): int32 {
		const run = (): int32 => { return this.n - 2; };
		const job = (): int32 => { return run() + 3; };
		return job();
	}

	param(k: int32): int32 {
		const run = (): int32 => { return k + this.n; };
		const job = (): int32 => {
			const deeper = (): int32 => { return run() * 2; };
			return deeper();
		};
		return job() - 2 * (this.n - 4);
	}

	plain(): int32 {
		const run = (): int32 => { return 7; };
		const job = (): int32 => { return run(); };
		return job();
	}
}

const box = new Box(5);
const other = new Box(3);
console.log(`sibling=${other.sibling()} param=${other.param(1)} ctor=${box.n} plain=${box.plain()}`);
