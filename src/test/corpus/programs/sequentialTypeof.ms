// @stdout: n:8 s:hi b:yes b:no
function read(x: int32 | string | boolean): string {
	let text = "";
	if (typeof x === "number") text = "n:" + (x + 1).toString();
	if (typeof x === "string") text = "s:" + x;
	if (typeof x === "boolean") text = "b:" + (x ? "yes" : "no");
	return text;
}
console.log(read(7), read("hi"), read(true), read(false));
