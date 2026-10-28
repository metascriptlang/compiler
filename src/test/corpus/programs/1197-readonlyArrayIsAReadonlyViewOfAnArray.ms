// @stdout: 3 6 3 5
function total(a: ReadonlyArray<int32>): int32 {
	let sum = 0;
	for (const v of a) sum += v;
	return sum;
}
function count(a: Readonly<int32[]>): int32 {
	return a.length;
}
function mixed(a: ReadonlyArray<int32 | string>): int32 {
	return a.length;
}
const xs: int32[] = [1, 2, 3];
const ms: Array<int32 | string> = [1, "b", 3, "d", 5];
console.log(count(xs), total(xs), mixed(ms.slice(0, 3)), mixed(ms));
