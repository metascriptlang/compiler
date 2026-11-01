// @stdout: 7 7 12
enum Kind { Slot, Const, Wild }
struct Position = match (kind: Kind) {
	Kind.Slot => { slot: int32 },
	Kind.Const => { value: int64 },
	Kind.Wild => {},
};

function fromParameters(a: Position, b: Position): int32 {
	if (a.kind === Kind.Const) { console.log(a.value); }
	let total: int32 = 0;
	for (const pos of [a, b]) {
		if (pos.kind === Kind.Slot) { total += pos.slot; }
	}
	return total;
}

function fromFields(pair: { left: Position; right: Position }): int32 {
	if (pair.left.kind === Kind.Const) { console.log(pair.left.value); }
	let total: int32 = 0;
	for (const pos of [pair.left, pair.right]) {
		if (pos.kind === Kind.Slot) { total += pos.slot; }
	}
	return total;
}

function afterEarlyReturn(a: Position, b: Position): int32 {
	if (a.kind === Kind.Const) return 0;
	let total: int32 = 0;
	for (const pos of [a, b]) {
		if (pos.kind === Kind.Slot) { total += pos.slot; }
	}
	return total;
}

const slot7: Position = { kind: Kind.Slot, slot: 7 };
const slot5: Position = { kind: Kind.Slot, slot: 5 };
const wild: Position = { kind: Kind.Wild };
console.log(`${fromParameters(slot7, wild)} ${fromFields({ left: slot7, right: wild })} ${afterEarlyReturn(slot7, slot5)}`);
