// @stdout: requesters 4 6 5 11
// @stdout: readonly 3 9 9 9 9
// @stdout: phantom 8 9 recursive 13
// @stdout: scoped 1 0
// @stdout: hooks ok

import { Box, Marker, Ticket, phantom, repeat, ticket, totals } from "./library";
import { left, leftShared } from "./left";
import { right, rightShared } from "./right";

interface Cell { value: int32; }

function view(value: Readonly<Cell>): int32 {
	const box = new Box<Readonly<Cell>>(value);
	return box.value.value;
}

function change(value: Cell): int32 {
	const box = new Box<Cell>(value);
	box.value.value = 9;
	return box.value.value;
}

function nested(values: Readonly<Cell>[]): int32 {
	const box = new Box<Readonly<Cell>[]>(values);
	const outer = new Box<Box<Readonly<Cell>[]>>(box);
	return outer.value.value[0].value;
}

function mutableNested(values: Cell[]): int32 {
	const box = new Box<Cell[]>(values);
	return box.value[0].value;
}

function localHooks(): void {
	const a = new Marker<int32>(11);
	const b = new Marker<string>(13);
	const first: Ticket<int32> = ticket<int32>(17, 19);
	const second: Ticket<string> = ticket<string>("s", 23);
	if (a.tag + b.tag + first.value + second.value.length != 42) throw new Error("generic values changed");
}

function scopedLeft(): int32 {
	type Token = distinct int32;
	const box = new Box<Token>(repeat<Token>(1 as Token, 2));
	return box.value as int32;
}

function scopedRight(): int32 {
	type Token = distinct int32;
	const box = new Box<Token>(repeat<Token>(0 as Token, 2));
	return box.value as int32;
}

console.log("requesters", left(), right(), leftShared(), rightShared());
const cell: Cell = { value: 3 };
const readonlyCells: Readonly<Cell>[] = [cell];
const mutableCells: Cell[] = [cell];
console.log("readonly", view(cell), change(cell), view(cell), nested(readonlyCells), mutableNested(mutableCells));
console.log("phantom", phantom<int32>(7), phantom<string>(8), "recursive", repeat<int32>(13, 4));
console.log("scoped", scopedLeft(), scopedRight());
localHooks();
when (c) { if (totals() != 3152) throw new Error("class/struct instance operation total: " + totals().toString()); }
console.log("hooks ok");
