// @stdout: 1 1 1 1
class Box {
	items: int32[] | null = null;
}

function inWhile(): int32 {
	let h: int32[] | null = null;
	while (true) {
		const k: int32 = h != null ? 1 : 0;
		if (h == null) {
			h = [k];
			continue;
		}
		return h.length;
	}
}

function inWhileIf(): int32 {
	let h: int32[] | null = null;
	while (true) {
		let k: int32 = 0;
		if (h != null) k = 1;
		if (h == null) {
			h = [k];
			continue;
		}
		return h.length;
	}
}

function inFor(): int32 {
	let h: int32[] | null = null;
	for (let i = 0; i < 3; i++) {
		const k: int32 = h != null ? 1 : 0;
		if (h == null) {
			h = [k];
			continue;
		}
		return h.length;
	}
	return -1;
}

function onField(): int32 {
	const b = new Box();
	while (true) {
		const k: int32 = b.items != null ? 1 : 0;
		if (b.items == null) {
			b.items = [k];
			continue;
		}
		return b.items.length;
	}
}

console.log(`${inWhile()} ${inWhileIf()} ${inFor()} ${onField()}`);
