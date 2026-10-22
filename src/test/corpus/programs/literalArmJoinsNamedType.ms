// @stdout: 9 1 9 9 0 | 9 1 9 | 11
// note: an object literal arm, plain or spread, with exactly the fields of the other arm's named type joins as that type: an unannotated const from a conditional (either arm order), `??`, `||` and a return takes the struct, the interface or the class, and a spread of that const is a spread of the named type. Same output on C and JS.
struct Box { rate: int32; size: int32; }
interface Face { rate: int32; size: int32; }
class Cls { rate: int32 = 5; size: int32 = 1; total(): int32 { return this.rate + this.size; } }

function boxes(base: Box, on: boolean): string {
	const picked = on ? base : { ...base, size: 9 };
	const flipped = on ? { ...base, size: 9 } : base;
	const nullish = (on ? null : base) ?? { ...base, size: 9 };
	const either = (on ? base : null) || { rate: 0, size: 9 };
	const again = { ...picked, rate: 0 };
	return `${picked.size} ${flipped.size} ${either.size} ${again.size} ${again.rate}` + (nullish.size == 1 ? "" : "!");
}

function faces(base: Face, on: boolean): string {
	const picked = on ? base : { ...base, size: 9 };
	const plain = on ? { rate: 2, size: 9 } : base;
	const viaReturn = (): Face => on ? base : { rate: 3, size: 9 };
	return `${picked.size} ${plain.size} ${viaReturn().size}`;
}

function classes(base: Cls, on: boolean): string {
	const picked = on ? base : { rate: 2, size: 9 };
	return `${picked.total()}`;
}

const face: Face = { rate: 5, size: 1 };
console.log(`${boxes({ rate: 5, size: 1 }, false)} | ${faces(face, false)} | ${classes(new Cls(), false)}`);
