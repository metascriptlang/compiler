// @stdout: live 3|ab
function neverCalled(): string[] {
	static const names: string[] = ["a", "b"];
	return names;
}

function counted(): int32[] {
	static const cells: int32[] = [1, 2, 3];
	return cells;
}

function joined(): string {
	static const parts: string[] = ["a", "b"];
	let out = "";
	for (const p of parts) out += p;
	return out;
}

console.log("live " + counted().length.toString() + "|" + joined());
