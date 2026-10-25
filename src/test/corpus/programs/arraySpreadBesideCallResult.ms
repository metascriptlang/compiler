// @stdout: last: len=1 x.ms
// @stdout: first: len=2 x.ms,-v
// @stdout: middle: len=4 -a,x.ms,-b,-c
// @stdout: returned
function pick(name: string): string {
	return name + ".ms";
}
function go(): void {
	const entry = pick("x");
	const flags: string[] = [];
	const all = [...flags, entry];
	console.log("last: len=" + all.length.toString() + " " + all.join(","));
	const more: string[] = ["-v"];
	const front = [entry, ...more];
	console.log("first: len=" + front.length.toString() + " " + front.join(","));
	const two: string[] = ["-b", "-c"];
	const mid = ["-a", pick("x"), ...two];
	console.log("middle: len=" + mid.length.toString() + " " + mid.join(","));
}
go();
console.log("returned");
