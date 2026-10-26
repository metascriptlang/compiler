// @stdout: x 5
// @stdout: 5 y 2.5 z true
// @stdout: a-1 7 b
// note: a console.log line that appends a number or boolean to the string it has built releases the string the append replaces.
function numbers(k: int32, d: float64, flag: boolean): void {
	console.log("x", k);
	console.log(k, "y", d, "z", flag);
}
function labelled(n: int32): void {
	const label = "a" + (-1).toString();
	console.log(label, n + 2, "b");
}
numbers(5, 2.5, true);
labelled(5);
