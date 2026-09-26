// GUARD-OS solana
// The string and array runtime compile under --os=solana, so a program that
// formats an integer, joins strings and sorts them links against them.
import { logU64 } from "std/solana";
function main(): void {
	const count: int64 = -42;
	const words: string[] = ["pear", "fig", count.toString()];
	words.sort();
	const joined = words.join(",");
	logU64(joined.length as uint64);
	logU64(parseInt("  -17") as uint64);
}
main();
