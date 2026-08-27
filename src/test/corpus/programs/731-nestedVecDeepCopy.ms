// @stdout: nested-vec-deep-copy done

// Vec<Vec<T>> assignment must deep-copy: classify routes nested-array elements to the
// per-type walker named by arrayCTypeName (the single naming source, see 624), not the
// generic payload-level msArrayCopy which shared inner buffers. Inner uint8 arrays go
// through msArrayUint8* (cap-flag aware), matching classifyArray's flat routing.

function check(name: string, ok: boolean): boolean {
	if (!ok) { console.log("FAIL " + name); }
	return ok;
}

function nested2(): boolean {
	const a: Vec<Vec<int32>> = [[1, 2], [3, 4]];
	const c: Vec<Vec<int32>> = a;
	c[0][0] = 99;
	c[1].push(5);
	return a[0][0] === 1 && a[1].length === 2 && c[0][0] === 99 && c[1].length === 3;
}

function nested3(): boolean {
	const a: Vec<Vec<Vec<int32>>> = [[[5]]];
	const c: Vec<Vec<Vec<int32>>> = a;
	c[0][0][0] = 77;
	return a[0][0][0] === 5 && c[0][0][0] === 77;
}

function nestedStr(): boolean {
	const a: Vec<Vec<string>> = [["x", "y"]];
	const c: Vec<Vec<string>> = a;
	c[0][0] = "mut";
	return a[0][0] === "x" && c[0][0] === "mut";
}

function nestedU8(): boolean {
	const a: Vec<Vec<uint8>> = [[1, 2]];
	const c: Vec<Vec<uint8>> = a;
	c[0][0] = 9 as uint8;
	return a[0][0] === 1 && c[0][0] === 9;
}

function reassign(): boolean {
	let a: Vec<Vec<int32>> = [[1]];
	const keep: Vec<Vec<int32>> = a;
	a = [[2]];
	return keep[0][0] === 1 && a[0][0] === 2;
}

function main(): void {
	let ok = true;
	ok = check("nested2", nested2()) && ok;
	ok = check("nested3", nested3()) && ok;
	ok = check("nestedStr", nestedStr()) && ok;
	ok = check("nestedU8", nestedU8()) && ok;
	ok = check("reassign", reassign()) && ok;
	if (ok) { console.log("nested-vec-deep-copy done"); }
}

main();
