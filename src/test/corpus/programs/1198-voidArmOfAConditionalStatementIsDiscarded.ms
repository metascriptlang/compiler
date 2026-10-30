// @stdout: x
// @stdout: y
// @stdout: z
// @stdout: done
function log(s: string): void {
	console.log(s);
}
function f(c: boolean): void {
	c ? log("x") : 5;
}
function g(c: boolean): void {
	c ? log("y") : log("no");
}
const h = (c: boolean): void => c ? 5 : log("z");
f(true);
g(true);
h(false);
console.log("done");
