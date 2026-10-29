// @stdout: span-push-other 1 2 3

struct Count { n: int32; }

function pushedStruct(rows: string[][]): int32 {
	const view: Readonly<Span<string[]>> = rows[0..rows.length];
	const out: Count[] = [];
	for (let i: int32 = 0; i < view.length; i++) out.push({ n: view[i].length as int32 });
	return out.length as int32;
}

function pushedScalar(rows: string[][]): int32 {
	const view: Readonly<Span<string[]>> = rows[0..rows.length];
	const out: int32[] = [];
	for (let i: int32 = 0; i < view.length; i++) out.push(view[i].length as int32);
	return out.length as int32;
}

function pushedArray(rows: string[][]): int32 {
	const view: Readonly<Span<string[]>> = rows[0..rows.length];
	const out: int32[][] = [];
	for (let i: int32 = 0; i < view.length; i++) out.push([view[i].length as int32, 7]);
	return out[0][0] + out[0][1] - 7 + 2;
}

console.log("span-push-other", pushedStruct([["a"]]), pushedScalar([["a"], ["b"]]), pushedArray([["a"]]));
