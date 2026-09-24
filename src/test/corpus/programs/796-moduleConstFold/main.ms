// @stdout: module-const-ok

import { WIDE, THIRD, STEP, ENABLED } from "./knobs";
import { exit } from "std/process";

enum StakeLevel { Whole, Half }

const LEVEL: int32 = (StakeLevel.Whole as int32) + 1;
const LOWEST: int32 = -2147483648;
const NEGATIVE: int64 = -9223372036854775807;

function main(): void {
	if (WIDE != 18446744073709551615) exit(1);
	if (THIRD != 6148914691236517205) exit(2);
	if (STEP != 8192 || !ENABLED) exit(3);
	if (LEVEL != 1) exit(4);
	if (LOWEST + 1 != -2147483647) exit(5);
	if (NEGATIVE + 9223372036854775807 != 0) exit(6);
	console.log("module-const-ok");
}

main();
