struct Pair<A, B> {
	first: A;
	second: B;
}

struct Slot {
	unit: int32;
	pair: Pair<string, string[]>;
}

class Printer {
	pairs: Pair<int32, string>[] = [];
	slots: Slot[] = [];
	names: string[] = [];
}

function pairOf(p: Printer, key: int32): Pair<int32, string> {
	const none: Pair<int32, string> = { first: -1, second: "" };
	for (const pair of p.pairs) {
		if (pair.first == key) return pair;
	}
	return none;
}

function slotOf(p: Printer, unit: int32): Slot {
	const none: Slot = { unit: -1, pair: { first: "", second: [] } };
	for (const slot of p.slots) {
		if (slot.unit == unit) return slot;
	}
	return none;
}

export function popsAndCopies(key: int32): string {
	const p = new Printer();
	p.pairs.push({ first: 3, second: "t" + key.toString() });
	p.names.push("a");
	p.names.push("b");
	const last = p.names.pop();
	return pairOf(p, key).second + last;
}

export function copiesPair(key: int32): string {
	const p = new Printer();
	p.pairs.push({ first: 3, second: "u" + key.toString() });
	const copy = pairOf(p, key);
	p.pairs[0].second = "changed";
	return copy.second;
}

export function copiesNestedSlot(unit: int32): string {
	const p = new Printer();
	p.slots.push({ unit: 7, pair: { first: "s" + unit.toString(), second: ["x", "y"] } });
	const copy = slotOf(p, unit);
	p.slots[0].pair.second.push("z");
	return copy.pair.first + copy.pair.second.join("");
}
