export struct Note { id: int32; text: string; }

let kept: string = "";
let keptNote: Note = { id: 0, text: "" };
let keptXs: Vec<int32> = [];

@wasm
export function stash(sink s: string): int32 {
	kept = s;
	return kept.length;
}

@wasm
export function stashed(): string {
	return kept;
}

@wasm
export function echo(sink s: string): string {
	return s;
}

@wasm
export function echoMaybe(sink s: string | null): string {
	return s ?? "none";
}

@wasm
export function keepNote(sink n: Note): int32 {
	keptNote = n;
	return keptNote.id;
}

@wasm
export function keptNoteText(): string {
	return keptNote.text;
}

@wasm
export function keepXs(sink xs: Vec<int32>): int32 {
	keptXs = xs;
	return keptXs.length;
}

@wasm
export function keptSum(): int32 {
	let total: int32 = 0;
	for (const x of keptXs) total += x;
	return total;
}
