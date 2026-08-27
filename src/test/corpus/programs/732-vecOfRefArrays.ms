// @stdout: vec-of-ref-arrays done

// Vec<T[]> is a VALUE seq of REF-array handles (same shape as Vec<SomeClass>):
// copying the Vec copies slots + increfs each handle, so mutation THROUGH a handle
// is visible from both copies, while slot replacement and push detach. classify's
// Ref branch must keep codegen's per-type struct name (elemIsRefArray, types.ms:1270)
// via arrayCTypeName instead of collapsing to msRefArray, or the C types mismatch.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function handleSharing(): boolean {
	const a: Vec<uint8[]> = [[1, 2]];
	const c: Vec<uint8[]> = a;
	c[0][0] = 9 as uint8;
	return a[0][0] === 9 && c[0][0] === 9;
}

function slotDetach(): boolean {
	const a: Vec<uint8[]> = [[1, 2]];
	const c: Vec<uint8[]> = a;
	c[0] = [7];
	return a[0][0] === 1 && a[0].length === 2 && c[0][0] === 7 && c[0].length === 1;
}

function pushDetach(): boolean {
	const a: Vec<int32[]> = [[1]];
	const c: Vec<int32[]> = a;
	c.push([5]);
	return a.length === 1 && c.length === 2 && c[1][0] === 5;
}

function reassignSink(): boolean {
	let a: Vec<uint8[]> = [[1]];
	const keep: Vec<uint8[]> = a;
	a = [[3]];
	return keep[0][0] === 1 && a[0][0] === 3;
}

function main(): void {
	let ok = true;
	ok = check("handleSharing", handleSharing()) && ok;
	ok = check("slotDetach", slotDetach()) && ok;
	ok = check("pushDetach", pushDetach()) && ok;
	ok = check("reassignSink", reassignSink()) && ok;
	if (ok) { console.log("vec-of-ref-arrays done"); }
}

main();
