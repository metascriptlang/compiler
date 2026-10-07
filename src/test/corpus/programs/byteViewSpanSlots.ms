// @stdout: byte view span slots 294 294 98 99 3 97 120 97 4 98 abc | 630720

function sum(bytes: Readonly<Span<uint8>>): int32 {
	let total: int32 = 0;
	for (const b of bytes) { total = total + (b as int32); }
	return total;
}

function at(bytes: Readonly<Span<uint8>>, i: int32): int32 {
	return bytes[i] as int32;
}

function bump(bytes: Span<uint8>): int32 {
	bytes[0] = (bytes[0] + 1) as uint8;
	return bytes[0] as int32;
}

function fresh(): string {
	return "x".repeat(3);
}

function build(i: int32): string {
	return "k" + String(i) + "x".repeat(i % 5);
}

function typedLocal(text: string): int32 {
	const raw: Readonly<Span<uint8>> = text.asBytes();
	return at(raw, 1);
}

function assigned(text: string): int32 {
	const other: uint8[] = [100, 101];
	let view: Readonly<Span<uint8>> = other;
	view = text.asBytes();
	return at(view, 2);
}

function viewLength(text: string): int32 {
	const view: Readonly<Span<uint8>> = text.asBytes();
	return view.length as int32;
}

function copied(text: string): uint8[] {
	return [...text.asBytes()];
}

function churn(): int32 {
	let acc: int32 = 0;
	let i: int32 = 0;
	while (i < 500) {
		const s = build(i);
		const t = build(i + 1);
		acc = acc + sum(s.asBytes()) + at(t.asBytes(), 1) + sum(build(i).asBytes());
		const span: Readonly<Span<uint8>> = t.asBytes();
		const second: Readonly<Span<uint8>> = s.asBytes();
		const kept = copied(s);
		kept.push(33);
		acc = acc + at(span, 0) + (second.length as int32) + kept.length + bump(kept);
		i = i + 1;
	}
	return acc;
}

function grown(text: string): string {
	const own = copied(text);
	own.push(100);
	return `${own.length} ${bump(own)}`;
}

const text = "abc";

function fromModuleConst(): int32 {
	const view = text.asBytes();
	return at(view, 0);
}

console.log(`byte view span slots ${sum(text.asBytes())} ${sum((text.asBytes()))} ${typedLocal(text)} ${assigned(text)} ${viewLength(text)} ${fromModuleConst()} ${at(fresh().asBytes(), 0)} ${at(text.asBytes(), 0)} ${grown(text)} ${text} | ${churn()}`);
