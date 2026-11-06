// @stdout: sized none,back,front|back|front,back,front|none,back,front|alpha,beta|10,20,30,40|10,20,30,40,5
import { FACES, GRID } from "./lib/tables";
const NAMES2: string[2] = ["alpha", "beta"];

function pick(i: int32): string { return FACES[i]; }

function joined(): string {
	let out = "";
	for (let i = 0; i < 3; i += 1) out = out + (i > 0 ? "," : "") + FACES[i];
	return out;
}

let copy = FACES;
copy[0] = "front";
let copied = "";
for (let i = 0; i < 3; i += 1) copied = copied + (i > 0 ? "," : "") + copy[i];

const names = NAMES2[0] + "," + NAMES2[1];
const grid = GRID[0].toString() + "," + GRID[1].toString() + "," + GRID[2].toString() + "," + GRID[3].toString();
const moved = [GRID[0], GRID[1], GRID[2], GRID[3], 5];
let movedText = "";
for (let i = 0; i < moved.length; i += 1) movedText = movedText + (i > 0 ? "," : "") + moved[i].toString();

console.log("sized " + joined() + "|" + pick(1) + "|" + copied + "|" + joined() + "|" + names + "|" + grid + "|" + movedText);
