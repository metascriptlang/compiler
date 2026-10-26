struct Cell { id: int32; }
struct Pair { left: Cell; right: Cell; }
struct Held { id: int32; }

let destroyed: int32 = 0;

function onDestroy(this x: Held): void {
	destroyed += 1;
}

function pairSum(p: Pair): int32 {
	return p.left.id + p.right.id;
}

function run(): void {
	let a: Cell = { id: 1 };
	const b = a;
	a = { id: 4 };
	const pair: Pair = { left: a, right: b };
	console.log(pair.left.id + pair.right.id);
	const cells: Cell[] = [];
	cells.push({ id: 3 });
	cells.push(a);
	console.log(pairSum(pair) + cells[0].id - 1);
	{
		const held: Held[] = [];
		held.push({ id: 1 });
		held.push({ id: 2 });
		held.push({ id: 3 });
		console.log(held.length);
	}
	console.log(destroyed - 1);
}

run();
console.log(destroyed + 10);
