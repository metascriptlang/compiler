// @stdout: true false false true
// note: a local narrowed to null that a closure assigns is compared through the type it stores, so `==` and `!=` read what the slot holds instead of the checker leaving a raw comparison for lowering to refuse.

function eqString(): boolean {
	let error: string | null = null;
	const keep = (x: string | null): void => { error = x; };
	if (error !== null) { return false; }
	keep("no");
	return error == "no";
}
function neInt(): boolean {
	let n: int32 | null = null;
	const set = (x: int32 | null): void => { n = x; };
	if (n !== null) { return false; }
	set(5);
	return n != 5;
}
function eqStruct(): boolean {
	let s: string | null = null;
	const keep = (x: string | null): void => { s = x; };
	if (s !== null) { return false; }
	return "no" == s;
}
function eqAfterAssertLike(): boolean {
	let error: string | null = null;
	const keep = (x: string | null): void => { error = x; };
	keep(null);
	if (error === null) { keep("late"); }
	return error == "late";
}
console.log(eqString(), neInt(), eqStruct(), eqAfterAssertLike());
