// @exit: 1
// @stdout: narrowed row N
// @xfail(danger): --danger elides the union narrowing check, so the read of the other member is undefined behaviour
// @xfail(raiser): the Raiser has no union narrowing check; the read yields the other member and prints V with exit 0
function pick(k: int32): number | string | null {
	if (k == 0) return 1;
	if (k == 1) return "row";
	return null;
}
function narrow(a: number | string | null): string | null {
	return a as string | null;
}
function run(): void {
	const present = narrow(pick(1));
	const absent = narrow(pick(2));
	console.log(`narrowed ${present === null ? "N" : present} ${absent === null ? "N" : "V"}`);
	const n = narrow(pick(0));
	console.log(n === null ? "N" : "V");
}
run();
