// @stdout: 1 w null|w 2 2|1.5 w null
// note: a ternary whose one branch is a scalar literal and the other a `number | string | null` is stored in a binding of that union, whichever branch the literal is in and whichever scalar it is
function either(k: int32): number | string | null { return k == 0 ? 0 : (k == 1 ? "w" : null); }

function literalFirst(k: int32, c: boolean): string {
	const a = c ? 1 : either(k);
	return `${a}`;
}

function literalLast(k: int32, c: boolean): string {
	const a = c ? either(k) : 2;
	return `${a}`;
}

function floatFirst(k: int32, c: boolean): string {
	const a = c ? 1.5 : either(k);
	return `${a}`;
}

console.log(`${literalFirst(1, true)} ${literalFirst(1, false)} ${literalFirst(2, false)}|${literalLast(1, true)} ${literalLast(1, false)} ${literalLast(2, false)}|${floatFirst(1, true)} ${floatFirst(1, false)} ${floatFirst(2, false)}`);
