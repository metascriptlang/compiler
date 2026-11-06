// @stdout: sized none,back,front|back|front,back,front|none,back,front|alpha,beta|10,20,30,40|10,20,30,40,5
// @stdout: push 4:alpha,beta,gamma,x y
// @stdout: write 3:zeta,e3,delta
// @stdout: splice 4:q,a,d,z
// @stdout: grew 25:9,213|3:red,green,blue
// @stdout: copy 3:uno,two,tres orig 2:one,two
// @stdout: nums 5:9,2,3,4,5
// @stdout: grown 5:18,4,6,8,10
// @stdout: floats 3 1.5 3.5
// @stdout: flags 3 true
import { FACES, GRID, LABELS } from "./lib/tables";
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

const PUSHED: string[] = ["alpha", "beta", "gamma"];
const WRITTEN: string[] = ["delta", "epsilon", "zeta"];
const SPLICED: string[] = ["a", "b", "c", "d"];
const UNTOUCHED: string[] = ["one", "two"];
const NUMS: int32[] = [1, 2, 3, 4];
const FLOATS: float64[] = [1.5, 2.5];
const FLAGS: boolean[] = [true, false, true];

function show(xs: string[]): string {
	let out = xs.length.toString() + ":";
	for (let i = 0; i < xs.length; i += 1) out = out + (i > 0 ? "," : "") + xs[i];
	return out;
}
function showN(xs: int32[]): string {
	let out = xs.length.toString() + ":";
	for (let i = 0; i < xs.length; i += 1) out = out + (i > 0 ? "," : "") + xs[i].toString();
	return out;
}

PUSHED.push("x");
PUSHED.push("y");
const tail = PUSHED.pop();
console.log("push " + show(PUSHED) + " " + tail);

WRITTEN[1] = "e" + WRITTEN.length.toString();
WRITTEN.reverse();
console.log("write " + show(WRITTEN));

SPLICED.splice(1, 2);
SPLICED.splice(0, 0, "q");
SPLICED.push("z");
console.log("splice " + show(SPLICED));

const sliced = UNTOUCHED.slice(0, UNTOUCHED.length);
sliced[0] = "uno";
sliced.push("tres");
console.log("copy " + show(sliced) + " orig " + show(UNTOUCHED));

NUMS.push(5);
NUMS[0] = 9;
console.log("nums " + showN(NUMS));
const grown: int32[] = [];
for (let i = 0; i < NUMS.length; i += 1) grown.push(NUMS[i] * 2);
console.log("grown " + showN(grown));

FLOATS.push(3.5);
console.log("floats " + FLOATS.length.toString() + " " + FLOATS[0].toString() + " " + FLOATS[2].toString());
FLAGS[1] = true;
console.log("flags " + FLAGS.length.toString() + " " + FLAGS[1].toString());

for (let i = 0; i < 20; i += 1) NUMS.push(i);
let sum = 0;
for (let i = 0; i < NUMS.length; i += 1) sum = sum + NUMS[i];
LABELS.push("blue");
console.log("grew " + NUMS.length.toString() + ":" + NUMS[0].toString() + "," + sum.toString() + "|" + LABELS.length.toString() + ":" + LABELS.join(","));
