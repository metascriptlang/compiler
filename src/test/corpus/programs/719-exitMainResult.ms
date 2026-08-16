// @stdout: exit-main got 5
// @exit: 5
function main(): int32 {
	console.log("exit-main got 5");
	return 5;
}

process.exit(main());
