// @stdout: local=59900 field=60100
// note: a Span held across an await lives in the routine's suspended state but owns nothing, as a view does everywhere else: releasing the state releases the Vec once, through its owner. Covers a view of a Vec local and a view of a Vec field of a struct local, each over many suspensions.

struct Bank { cells: Vec<int32>; base: int32; }

async function settle(n: int32): Promise<int32> {
	return n * 2;
}

async function localView(n: int32): Promise<int32> {
	let local: Vec<int32> = [n, n + 1];
	const view: Span<int32> = local;
	const doubled = await settle(view[0]);
	return doubled + view[1];
}

async function fieldView(n: int32): Promise<int32> {
	let bank: Bank = { cells: [n, n + 1, n + 2], base: 0 };
	const view: Span<int32> = bank.cells;
	const doubled = await settle(view[bank.base]);
	return doubled + view[2];
}

let local = 0;
let field = 0;
async function all(): Promise<void> {
	for (let i: int32 = 0; i < 200; i += 1) {
		local += await localView(i);
		field += await fieldView(i);
	}
}
all().then((): void => { console.log(`local=${local} field=${field}`); });
