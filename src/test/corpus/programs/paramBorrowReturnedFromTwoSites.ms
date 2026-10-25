// @stdout: sel 11 5 head 7 1
// Variant of elementReceiverAndParamBorrowKeepIdentity: a borrow of a by-value first parameter leaves through two
// return sites, or as an element of it, and still points at the caller's value.
// note: a ternary over two parameters cannot carry the borrow: the checker refuses it, since a Borrow return must be a path from the first parameter.

function sel(s: string, k: boolean): Borrow<string> {
	if (k) return s;
	return s;
}
function head(v: Vec<int32>): Borrow<int32> { return v[0]; }

function main(): void {
	const rows: Vec<Vec<int32>> = [[1, 2]];
	console.log("sel", sel("hello world", true).length, sel("short", false).length, "head", head([7, 3]), head(rows[0]));
}

main();
