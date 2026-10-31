export struct Label { text: string; tag: string; count: int32; }

@wasm
export function keep(s: string): string {
	const held: string[] = [];
	held.push(s);
	let t = s;
	t += "!";
	held.push(t);
	return held.join("|");
}

@wasm
export function echo(s: string): string {
	return s;
}

@wasm
export function join2(a: string, n: int32, b: string): string {
	return `${a}:${n}:${b}`;
}

@wasm
export function relabel(l: Label): Label {
	return { text: l.tag + l.text, tag: l.text, count: l.text.length + l.tag.length };
}

@wasm
export function relay(s: string, callback: (t: string) => int32): int32 {
	return callback(s) + callback(s + "!");
}

@wasm
export function lengthOf(s: string): int32 {
	return s.length;
}
