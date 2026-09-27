export struct Pair {
	a: int32;
	b: int32;
}

export class Box {
	v: int32 = 0;
}

function parse(text: string): Result<int32, string> {
	return text == "7" ? Result.ok(7) : Result.err(text);
}

let pair: Pair = { a: 1, b: 2 };
let names: string[] = [];
let box: Box = new Box();
let label: string | null = null;
let counts = new Map<string, int32>();
let parsed: Result<int32, string> = parse("7");

export function record(n: int32): void {
	names.push(`n${n}`);
	box.v += n;
	pair = { a: pair.a + n, b: pair.b };
	label = `seen ${n}`;
	counts.set("calls", (counts.get("calls") ?? 0) + 1);
}

export function describe(): string {
	const text = label ?? "none";
	return `v1 ${names.join(",")} box ${box.v} pair ${pair.a} ${text} calls ${counts.get("calls") ?? 0} parsed ${parsed.ok}`;
}
