// @stdout: 2/n!/2.5/false/4:14|6/~/~/~/1:~|10/!/0/true/0:10|~
// @stdout: 4,9,8
// @stdout: [0,0.5,1]|[]|~
// @stdout: 2,-1,0
import { bump, firstOr, upTo, countTrue, Item } from "./nullableCopiesWasm";

function showInt(v: int32 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showText(v: string | null): string {
	if (v == null) { return "~"; }
	return v;
}

function showNum(v: float64 | null): string {
	if (v == null) { return "~"; }
	return `${v}`;
}

function showFlag(v: boolean | null): string {
	if (v == null) { return "~"; }
	return v ? "true" : "false";
}

function showItem(r: Item | null): string {
	if (r == null) { return "~"; }
	return `${r.id}/${showText(r.note)}/${showNum(r.score)}/${showFlag(r.ok)}/${r.at.x}:${showInt(r.at.y)}`;
}

function showVec(v: Vec<float32> | null): string {
	if (v == null) { return "~"; }
	return `[${v.join(",")}]`;
}

const a: Item = { id: 1, note: "n", score: 1.25, ok: true, at: { x: 3, y: 4 } };
const b: Item = { id: 5, note: null, score: null, ok: null, at: { x: 0, y: null } };
const c: Item = { id: 9, note: "", score: 0, ok: false, at: { x: -1, y: 0 } };
console.log([showItem(bump(a)), showItem(bump(b)), showItem(bump(c)), showItem(bump(null))].join("|"));
const xs: Vec<int32> = [4, 5];
const empty: Vec<int32> = [];
console.log(`${firstOr(xs, 9)},${firstOr(null, 9)},${firstOr(empty, 9)}`);
console.log([showVec(upTo(3)), showVec(upTo(0)), showVec(upTo(-1))].join("|"));
const flags: Vec<boolean> = [true, false, true];
const none: Vec<boolean> = [];
console.log(`${countTrue(flags)},${countTrue(null)},${countTrue(none)}`);
