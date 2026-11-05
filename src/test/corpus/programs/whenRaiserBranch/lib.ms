export function importedWhere(): string {
	when (raiser) {
		const tag = "vm";
		return tag;
	} else {
		const tag = "native";
		return tag;
	}
}

export function firstOf<T>(items: T[], fallback: T): T {
	let picked: T = fallback;
	when (raiser) {
		if (items.length > 0) picked = items[0];
	} else {
		if (items.length > 0) picked = items[items.length - 1];
	}
	return picked;
}
