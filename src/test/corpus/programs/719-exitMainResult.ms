// @stdout: exit-main got 5
// @exit: 5
import { exit } from "std/process";

function main(): int32 {
	console.log("exit-main got 5");
	return 5;
}

exit(main());
