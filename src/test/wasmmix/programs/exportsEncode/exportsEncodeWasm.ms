export struct Note { text: string; weight: int32; }

@wasm
export function size(s: string): int32 {
	return s.length;
}

@wasm
export function weigh(n: Note): int32 {
	return n.text.length * n.weight;
}
