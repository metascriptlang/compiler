// @stdout: element-receiver 3/3/2 4 param-borrow 11 7 5
// A mutating call on an element keeps writing that element, and a borrow returned from a parameter points at the caller's value.

class Box {
	items: string[] = [];
}

function lens(s: string): Borrow<string> { return s; }
function same(n: int32): Borrow<int32> { return n; }
function inner(rows: Vec<Vec<int32>>): Borrow<Vec<int32>> { return rows[0]; }

function main(): void {
	let grid: Vec<Vec<Vec<int32>>> = [[[1, 2]]];
	grid[0][0].push(3);
	let words: Vec<Vec<string>> = [["a"]];
	words[0].push("b");
	words[0].push("c");
	const box = new Box();
	box.items.push("x");
	box.items.push("y");
	const rows: Vec<Vec<int32>> = [[1, 2, 3, 4]];
	console.log(`element-receiver ${grid[0][0].length}/${words[0].length}/${box.items.length} ${inner(rows).length}`, "param-borrow", lens("hello world").length, same(7), lens("short").length);
}

main();
