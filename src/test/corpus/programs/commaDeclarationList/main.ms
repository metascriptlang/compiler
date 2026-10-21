// @stdout: 1 2 3 4|10 11|5 6 7|9|8 9|x y 3|1 2
// note: a const, let or export declaration list binds each name left to right in the enclosing scope, the same as one statement per name, on every backend.
import { base, next } from "./values";

const left = 1, right = 2;
let first = 3, second = 4;
const parts: string[] = [];
parts.push(`${left} ${right} ${first} ${second}`);
parts.push(`${base} ${next}`);

function chain(start: int32): string {
	const a = start, b = a + 1, c = b + 1;
	return `${a} ${b} ${c}`;
}
parts.push(chain(5));

let later: int32, count = 0;
later = 9;
count = count + later;
parts.push(`${count}`);

function picked(k: int32): string {
	switch (k) {
		case 1:
			const lo = 8, hi = lo + 1;
			return `${lo} ${hi}`;
		default:
			return "none";
	}
}
parts.push(picked(1));

const { x, y } = { x: "x", y: "y" }, total = 3;
parts.push(`${x} ${y} ${total}`);

let i = 1, j = 2;
i = i + 0;
j = j + 0;
parts.push(`${i} ${j}`);
console.log(parts.join("|"));
