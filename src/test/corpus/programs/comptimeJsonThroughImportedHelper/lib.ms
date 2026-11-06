export function roundTrip(text: string): string {
	const r = parseJson(text);
	return r.ok ? stringify(r.value) : r.error;
}

export function wide(count: int32, distinctKeys: int32): string {
	let text = "{";
	for (let i = 0; i < count; i = i + 1) text = text + `"k${i % distinctKeys}":${i},`;
	return text + `"k0":"end"}`;
}
