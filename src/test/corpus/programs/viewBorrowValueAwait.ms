// @stdout: await=12/2/7
// note: a Vec view on a value path that nothing captures stays legal and reads the same slots after an await, for a Vec local and for a Vec field of a value-struct local.

struct Bank { cells: Vec<int32>; base: int32; }

async function settle(n: int32): Promise<int32> {
	return n * 2;
}

async function viewAcrossAwait(): Promise<string> {
	let bank: Bank = { cells: [5, 6, 7], base: 0 };
	let local: Vec<int32> = [1, 2];
	const localView: Span<int32> = local;
	const fieldView: Span<int32> = bank.cells;
	const doubled = await settle(localView[0] + fieldView[0]);
	return `${doubled}/${localView[1]}/${fieldView[2]}`;
}

const awaited = await viewAcrossAwait();
console.log(`await=${awaited}`);
