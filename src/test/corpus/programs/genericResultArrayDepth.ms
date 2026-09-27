// @stdout: result arrays 7 9

function fetch<T>(): Result<T[], string> { return Result.ok([] as T[]); }
function nested<T>(): Result<T[][], string> { return Result.ok([] as T[][]); }
function run(): void {
	const flat = fetch<int32>();
	const deep = nested<int32>();
	if (!flat.ok || !deep.ok) { console.log("unexpected error"); return; }
	const values: int32[] = flat.value;
	const rows: int32[][] = deep.value;
	values.push(7);
	rows.push([9]);
	console.log(`result arrays ${values[0]} ${rows[0][0]}`);
}
run();
