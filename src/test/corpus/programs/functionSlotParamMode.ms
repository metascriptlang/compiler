// @stdout: 2 7 5
// note: a function slot typed with a `ref` or `out` parameter holds a function that takes the parameter the same way, and the call through the slot writes the caller's variable in place.

function bump(ref x: int32): void {
	x += 1;
}

function fill(out x: int32): void {
	x = 7;
}

function viaRef(f: (ref x: int32) => void): int32 {
	let v: int32 = 1;
	f(v);
	return v;
}

function viaOut(f: (out x: int32) => void): int32 {
	let v: int32;
	f(out v);
	return v;
}

function viaVal(f: (x: int32) => int32): int32 {
	return f(5);
}

console.log(viaRef(bump), viaOut(fill), viaVal((x: int32) => x));
