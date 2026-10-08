// @stdout: getter=16/3 sibling=15/11 slot=9/70 reader=6/3/10/4 retaken=1/4/4 loop=11/4
// note: a Vec view on a value path (a Vec local, or a Vec field of a value-struct local) stays legal and reads the live slots through a by-value getter, a sibling field write, a slot write, a by-value pass, and a view re-taken after a push.

struct Bank { cells: Vec<int32>; base: int32; }

function total(this bank: Bank): int32 {
	let sum = bank.base;
	for (const cell of bank.cells) { sum += cell; }
	return sum;
}

function sumOf(cells: Vec<int32>): int32 {
	let sum = 0;
	for (const cell of cells) { sum += cell; }
	return sum;
}

function valueGetter(): string {
	let bank: Bank = { cells: [1, 2, 3], base: 10 };
	const view: Span<int32> = bank.cells;
	const sum = bank.total();
	return `${sum}/${view[2]}`;
}

function siblingWrite(): string {
	let bank: Bank = { cells: [4, 5, 6], base: 10 };
	const view: Span<int32> = bank.cells;
	bank.base = 11;
	return `${view[0] + view[1] + view[2]}/${bank.base}`;
}

function slotWrite(): string {
	let bank: Bank = { cells: [1, 2, 3], base: 0 };
	let local: Vec<int32> = [7, 8, 9];
	const fieldView: Span<int32> = bank.cells;
	const localView: Span<int32> = local;
	bank.cells[1] = 9;
	local[0] = 70;
	return `${fieldView[1]}/${localView[0]}`;
}

function byValueReader(): string {
	let bank: Bank = { cells: [1, 2, 3], base: 10 };
	let local: Vec<int32> = [1, 2, 3, 4];
	const fieldView: Span<int32> = bank.cells;
	const localView: Span<int32> = local;
	const fieldSum = sumOf(bank.cells);
	const localSum = sumOf(local);
	return `${fieldSum}/${fieldView[2]}/${localSum}/${localView[3]}`;
}

function retakenAfterPush(): string {
	let local: Vec<int32> = [1, 2, 3];
	const before: Span<int32> = local;
	const first = before[0];
	local.push(4);
	const after: Span<int32> = local;
	return `${first}/${after.length}/${after[3]}`;
}

function retakenInLoop(): string {
	let local: Vec<int32> = [1];
	let sum = 0;
	for (let i = 0; i < 3; i++) {
		const view: Span<int32> = local;
		sum += view[i];
		local.push(i * 10);
	}
	return `${sum}/${local.length}`;
}

console.log(
	`getter=${valueGetter()} sibling=${siblingWrite()} slot=${slotWrite()} ` +
	`reader=${byValueReader()} retaken=${retakenAfterPush()} loop=${retakenInLoop()}`,
);
