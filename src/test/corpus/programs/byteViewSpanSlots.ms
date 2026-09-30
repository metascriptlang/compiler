// @stdout: byte view span slots 294 294 98 99 3 97 120 97 98 2 98 | 573830

struct Chunk {
	bytes: Span<uint8>;
}

function sum(bytes: Span<uint8>): int32 {
	let total: int32 = 0;
	for (const b of bytes) { total = total + (b as int32); }
	return total;
}

function at(bytes: Span<uint8>, i: int32): int32 {
	return bytes[i] as int32;
}

function secondOf(bytes: Readonly<uint8[]>): int32 {
	return bytes[1] as int32;
}

function fresh(): string {
	return "x".repeat(3);
}

function build(i: int32): string {
	return "k" + String(i) + "x".repeat(i % 5);
}

function typedLocal(text: string): int32 {
	const raw: Span<uint8> = text.asBytes();
	return at(raw, 1);
}

function assigned(text: string): int32 {
	const other: uint8[] = [100, 101];
	let view: Span<uint8> = other;
	view = text.asBytes();
	return at(view, 2);
}

function fieldLength(text: string): int32 {
	const chunk: Chunk = { bytes: text.asBytes() };
	return chunk.bytes.length as int32;
}

function churn(): int32 {
	let acc: int32 = 0;
	let i: int32 = 0;
	while (i < 500) {
		const s = build(i);
		const t = build(i + 1);
		acc = acc + sum(s.asBytes()) + secondOf(t.asBytes()) + sum(build(i).asBytes());
		const span: Span<uint8> = t.asBytes();
		const chunk: Chunk = { bytes: s.asBytes() };
		acc = acc + at(span, 0) + (chunk.bytes.length as int32) + (s.asBytes().slice(1, 2).length as int32);
		i = i + 1;
	}
	return acc;
}

function slicePair(text: string): string {
	const part = text.asBytes().slice(1, 3);
	return `${part.length} ${part[0]}`;
}

const text = "abc";
const top: Span<uint8> = text.asBytes();
console.log(`byte view span slots ${sum(text.asBytes())} ${sum((text.asBytes()))} ${typedLocal(text)} ${assigned(text)} ${fieldLength(text)} ${at(top, 0)} ${at(fresh().asBytes(), 0)} ${at(text.asBytes(), 0)} ${secondOf(text.asBytes())} ${slicePair(text)} | ${churn()}`);
