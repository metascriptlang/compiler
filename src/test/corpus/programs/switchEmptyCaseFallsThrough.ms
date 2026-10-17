// An empty case falls into the next one: two and three stacked labels, a label stacked onto default, and a string
// discriminant (the match-lowered path). Stacked labels also count as one path for the ending-return check.
// @stdout: 5 5 9|7 7 7 4 0|1 8 8|2 2 3 0
function pick(i: int32): int32 {
	let s = 0;
	switch (i) {
		case 1:
		case 2:
			s = 5;
			break;
		default:
			s = 9;
	}
	return s;
}
function three(i: int32): int32 {
	switch (i) {
		case 1:
		case 2:
		case 3:
			return 7;
		case 4:
			return 4;
	}
	return 0;
}
function intoDefault(i: int32): int32 {
	switch (i) {
		case 1:
			return 1;
		case 2:
		default:
			return 8;
	}
}
function str(s: string): int32 {
	switch (s) {
		case "a":
		case "b":
			return 2;
		case "c":
			return 3;
		default:
			return 0;
	}
}
console.log(`${pick(1)} ${pick(2)} ${pick(3)}|${three(1)} ${three(2)} ${three(3)} ${three(4)} ${three(5)}|${intoDefault(1)} ${intoDefault(2)} ${intoDefault(3)}|${str("a")} ${str("b")} ${str("c")} ${str("d")}`);
