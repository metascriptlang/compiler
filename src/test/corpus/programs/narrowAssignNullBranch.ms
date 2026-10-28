// @stdout: 3 1 7 4 5 6
// note: an assignment in the null branch gives the local its assigned type at the join, so the default-filling idiom narrows a nullable local like it does in TS; Maybe-wrapped (string, int32) and pointer-free alike.

function find(hit: boolean): string | null { return hit ? "a" : null; }
function findNum(hit: boolean): int32 | null { return hit ? 7 : null; }
function fallback(): string { return "four"; }

function plain(hit: boolean): int32 {
	let part = find(hit);
	if (part == null) { part = "xyz"; }
	return part.length;
}
function fromCall(hit: boolean): int32 {
	let part = find(hit);
	if (part == null) { part = fallback(); }
	return part.length;
}
function elseAssigns(hit: boolean): int32 {
	let n = findNum(hit);
	if (n == null) { n = 5; } else { n = n + 0; }
	return n;
}
function nested(hit: boolean, deep: boolean): int32 {
	let n = findNum(hit);
	if (n == null) {
		if (deep) { n = 5; } else { n = 6; }
	}
	return n;
}
function numberFromNull(hit: boolean): int32 {
	let n = findNum(hit);
	if (n == null) { n = 5; }
	return n;
}

console.log(plain(false), plain(true), numberFromNull(true), fromCall(false), nested(false, true), nested(false, false));
