// @stdout: grid 3/1 rows 4/5
// Variant of elementReceiverAndParamBorrowKeepIdentity: the element push sits two helpers below the caller, on a
// parameter's field path, and on a Vec element written in place; each push lands in the element, not in a copy.

class Grid {
	rows: Vec<Vec<int32>> = [[1], [2]];
}

function pushAt(g: Grid, i: int32, v: int32): void { g.rows[i].push(v); }
function fill(g: Grid, i: int32): void {
	pushAt(g, i, 5);
	pushAt(g, i, 6);
}

function main(): void {
	const g = new Grid();
	fill(g, 0);
	let rows: Vec<Vec<int32>> = [[1, 2, 3], [1, 2, 3]];
	rows[0].push(4);
	rows[1].push(4);
	rows[1].push(5);
	console.log(`grid ${g.rows[0].length}/${g.rows[1].length} rows ${rows[0].length}/${rows[1].length}`);
}

main();
