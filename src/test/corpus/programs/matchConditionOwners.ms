// @stdout: 10 20|63:4578|8:01234|5:123|2:12|2:00112233|2:012|7:9
// @exit: 0

let events: string = "";
function mark(value: int32): int32 {
	events += value.toString();
	return value;
}

function direct(value: int32): int32 {
	if (match (value) { 1 => true, _ => false }) { return 10; }
	return 20;
}

function branches(f: boolean, t: boolean): int32 {
	let score: int32 = 0;
	if (f && (match (mark(1)) { 1 => true, _ => false })) { score += 100; }
	if (t || (match (mark(2)) { 2 => true, _ => false })) { score += 1; }
	if (f ? (match (mark(3)) { 3 => true, _ => false }) : (match (mark(4)) { 4 => true, _ => false })) { score += 2; }
	if (!(match (mark(5)) { 5 => false, _ => true })) { score += 4; }
	if (t) { score += 8; }
	else if (match (mark(6)) { 6 => true, _ => false }) { score += 100; }
	if (f) { score += 100; }
	else if (f) { score += 100; }
	else if (match (mark(7)) { 7 => true, _ => false }) { score += 16; }
	if (t) if (match (mark(8)) { 8 => true, _ => false }) score += 32;
	return score;
}

function whileCondition(): int32 {
	let i: int32 = 0;
	let sum: int32 = 0;
	while (match (mark(i)) { 0 | 1 | 2 | 3 => true, _ => false }) {
		i += 1;
		if (i == 2) { continue; }
		sum += i;
	}
	return sum;
}

function doCondition(): int32 {
	let i: int32 = 0;
	let sum: int32 = 0;
	do {
		i += 1;
		if (i == 1) { continue; }
		let inner: int32 = 0;
		while (inner < 2) { inner += 1; continue; }
		sum += i;
	} while (match (mark(i)) { 1 | 2 => true, _ => false });
	return sum;
}

function doJumps(): int32 {
	let i: int32 = 0;
	let sum: int32 = 0;
	do {
		i += 1;
		match (i) {
			1 => { continue; },
			3 => { break; },
			_ => { sum += i; },
		};
	} while (match (mark(i)) { 1 | 2 => true, _ => false });
	return sum;
}

function forHeaders(): int32 {
	let sum: int32 = 0;
	for (let i = match (mark(0)) { 0 => 0, _ => 9 };
		match (mark(i)) { 0 | 1 | 2 => true, _ => false };
		i = match (mark(i + 1)) { _ => i + 1 }) {
		if (i == 1) { continue; }
		sum += i;
	}
	return sum;
}

function bareLoopBody(): int32 {
	let i: int32 = 0;
	while (match (mark(i)) { 0 | 1 => true, _ => false }) i += 1;
	return i;
}

function guardedArm(value: int32): int32 {
	return match (value) {
		1 when (match (mark(9)) { 9 => true, _ => false }) => 7,
		_ => 8,
	};
}

const output: string[] = [];
output.push(`${direct(1)} ${direct(2)}`);
const empty: int32[] = [];
const f = empty.length > 0;
const t = empty.length == 0;
const branchScore = branches(f, t);
output.push(`${branchScore}:${events}`);
events = "";
const whileScore = whileCondition();
output.push(`${whileScore}:${events}`);
events = "";
const doScore = doCondition();
output.push(`${doScore}:${events}`);
events = "";
const jumpScore = doJumps();
output.push(`${jumpScore}:${events}`);
events = "";
const forScore = forHeaders();
output.push(`${forScore}:${events}`);
events = "";
const bareScore = bareLoopBody();
output.push(`${bareScore}:${events}`);
events = "";
const guardScore = guardedArm(1);
output.push(`${guardScore}:${events}`);
console.log(output.join("|"));
