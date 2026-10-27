// @stdout: dump=a {"message":"x"}
// note: valueDump expands a macro that builds Node object literals inside the VM; a class with no laid field must keep taking named fields there (an empty class is a cell only when its destroy routine needs one).

function main(): void {
	const e = new Error("x");
	console.log("dump=" + "a " + e);
}
main();
