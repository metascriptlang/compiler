// @stdout: rows=3 flexDirection:FlexDirection:word keys=a|b|c last=len has=true,false idx=1 total=6 copy=2,3,3
// note: a macro-time helper reads module-level const arrays: a table of rows indexed and iterated, a flat list with includes, indexOf and map, and a copy a helper takes of one.

import { Node, NodeKind } from "std/meta";

export const TABLE: string[][] = [
	["flexDirection", "FlexDirection", "word"],
	["gap", "number | string", "len"],
	["opacity", "number", "num"],
];

const KEYS: string[] = ["a", "b", "c"];
const SIZES: int32[] = [1, 2, 3];

function firstRow(): string {
	const row = TABLE[0];
	return row[0] + ":" + row[1] + ":" + row[2];
}

function lastKind(): string {
	let kind = "";
	for (const row of TABLE) kind = row[2];
	return kind == "num" ? "len" : kind;
}

function total(): int32 {
	let sum = 0;
	for (const n of SIZES) sum += n;
	return sum;
}

function sizesCopy(): string {
	const mine = SIZES.slice(1, 3);
	mine.push(3);
	return String(mine[0]) + "," + String(mine[1]) + "," + String(mine.length);
}

macro report(): Node {
	const text = "rows=" + String(TABLE.length)
		+ " " + firstRow()
		+ " keys=" + KEYS.join("|")
		+ " last=" + lastKind()
		+ " has=" + String(KEYS.includes("b")) + "," + String(KEYS.includes("z"))
		+ " idx=" + String(KEYS.indexOf("b"))
		+ " total=" + String(total())
		+ " copy=" + sizesCopy();
	return { kind: NodeKind.StringLiteral, line: 1, column: 1, value: text };
}

console.log(report());
