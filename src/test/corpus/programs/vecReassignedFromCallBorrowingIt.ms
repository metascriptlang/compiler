// @stdout: span 700 outer 700 two 700 vec 700 bytes 49
// @exit: 0

function spanInner(items: Readonly<Span<int64>>): Vec<int64> {
	let noise: Vec<int64> = [];
	for (let i: int64 = 0; i < 64; i += 1) { noise.push(i + 1000); }
	let out: Vec<int64> = [];
	for (const item of items) { out.push(item * 10); }
	return out;
}

function spanOuter(items: Readonly<Span<int64>>): Vec<int64> {
	return spanInner(items);
}

function vecInner(items: Readonly<Vec<int64>>): Vec<int64> {
	let noise: Vec<int64> = [];
	for (let i: int64 = 0; i < 64; i += 1) { noise.push(i + 1000); }
	let out: Vec<int64> = [];
	for (const item of items) { out.push(item * 10); }
	return out;
}

function bytesInner(items: Readonly<Span<uint8>>): Vec<uint8> {
	let noise: Vec<uint8> = [];
	for (let i = 0; i < 64; i += 1) { noise.push(200); }
	let out: Vec<uint8> = [];
	for (const item of items) { out.push(item + 1); }
	return out;
}

function span(rounds: int32): int64 {
	let entries: Vec<int64> = [7];
	for (let round = 0; round < rounds; round += 1) { entries = spanInner(entries); }
	return entries[0];
}

function outer(rounds: int32): int64 {
	let entries: Vec<int64> = [7];
	for (let round = 0; round < rounds; round += 1) { entries = spanOuter(entries); }
	return entries[0];
}

function two(rounds: int32): int64 {
	let entries: Vec<int64> = [7];
	for (let round = 0; round < rounds; round += 1) {
		const next = spanOuter(entries);
		entries = next;
	}
	return entries[0];
}

function vec(rounds: int32): int64 {
	let entries: Vec<int64> = [7];
	for (let round = 0; round < rounds; round += 1) { entries = vecInner(entries); }
	return entries[0];
}

function bytes(rounds: int32): int32 {
	let entries: Vec<uint8> = [1];
	for (let round = 0; round < rounds; round += 1) { entries = bytesInner(entries); }
	return entries[0];
}

console.log(`span ${span(2)} outer ${outer(2)} two ${two(2)} vec ${vec(2)} bytes ${bytes(48) }`);
