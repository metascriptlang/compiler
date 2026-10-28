// @stdout: 1 7 a 3 2 x-y-z
function first<T>(...v: T[]): T {
	return v[0];
}
function rest<T>(head: T, ...tail: T[]): T[] {
	return tail;
}
function join<T>(sep: string, ...v: T[]): string {
	let out = "";
	for (let i = 0; i < v.length; i += 1) {
		out = out + (i > 0 ? sep : "") + v[i];
	}
	return out;
}
const xs: int32[] = [7, 8, 9];
const parts: string[] = ["x", "y", "z"];
console.log(first(1, 2, 3), first(...xs), first("a", "b"), rest(1, 2, 3).length + 1, rest("a", "b", "c").length, join("-", ...parts));
