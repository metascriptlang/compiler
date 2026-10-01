import { Cell, labels } from "./cell";

struct Note {
	body: string;
	weight: int32;
}

export function cellRounds(count: int32): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < count; i += 1) {
		let owned: Vec<Cell> = new Array(0);
		owned.push({ text: "delta" + i });
		let copied = owned;
		copied.push({ text: "epsilon" + i });
		total += (owned.length + copied.length) as int32;
		for (const cell of labels(i)) total += cell.text.length as int32;
	}
	return total;
}

export function noteRounds(count: int32): int32 {
	let total: int32 = 0;
	for (let i: int32 = 0; i < count; i += 1) {
		let notes: Vec<Note> = new Array(0);
		notes.push({ body: "n" + i, weight: i });
		let kept = notes;
		kept.push({ body: "m" + i, weight: 1 });
		for (const note of kept) total += note.weight + note.body.length as int32;
		total += notes.length as int32;
	}
	return total;
}
