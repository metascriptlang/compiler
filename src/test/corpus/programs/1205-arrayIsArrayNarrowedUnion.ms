// @stdout: arr2 str:s true false
function describe(u: string | string[]): string {
	if (typeof u == "string") return "str:" + u;
	return "arr" + u.length + (Array.isArray(u) ? "" : "!");
}
const a: string | string[] = ["x", "y"];
const b: string | string[] = "s";
console.log(`${describe(a)} ${describe(b)} ${Array.isArray(["x"])} ${Array.isArray("s")}`);
