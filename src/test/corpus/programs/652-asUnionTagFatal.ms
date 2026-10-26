// @exit: 1
// @stdout: before center
// @xfail(danger): --danger drops the tag test, so the read of the other member is undefined behaviour

function textOf(u: number | string): string {
	return u as string;
}

function main(): void {
	console.log(`before ${textOf("center")}`);
	console.log(`after ${textOf(7)}`);
}
main();
