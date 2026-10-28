// @stdout: local=1,2,6 nested=3 global=4
// @exit: 0

struct Pet { n: int32; }
struct Holder { tag: int32; held: Pet | string; }
struct Tally { tag: int32; held: Pet | int32; }
struct Outer { inner: Tally; }

enum Kind { Cat, Dog }
struct Shape = match (kind: Kind) {
	Kind.Cat => { lives: int32 },
	Kind.Dog => { bark: float32, loud: boolean },
};
struct Pen { id: int32; shape: Shape; }

function local(): string {
	const pet: Holder = { tag: 1, held: { n: 4 } };
	const word: Holder = { tag: 2, held: "x".repeat(3) };
	const plain: Tally = { tag: 6, held: { n: 7 } };
	return `${pet.tag},${word.tag},${plain.tag}`;
}

function nested(): int32 {
	const o: Outer = { inner: { tag: 3, held: { n: 5 } } };
	return o.inner.tag;
}

const dog: Shape = { kind: Kind.Dog, bark: 1.5, loud: true };
const pen: Pen = { id: 4, shape: dog };

console.log(`local=${local()} nested=${nested()} global=${pen.id}`);
