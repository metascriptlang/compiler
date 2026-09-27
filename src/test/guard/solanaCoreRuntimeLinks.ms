// GUARD-OS solana
import { logU64 } from "std/solana";
function main(): void {
	const count: int64 = -42;
	const words: string[] = ["pear", "fig", count.toString()];
	words.sort();
	const joined = words.join(",");
	logU64(joined.length as uint64);
	logU64(parseInt("  -17") as uint64);
	const ratio: number = 0.1 + 0.2;
	logU64(ratio.toString().length as uint64);
}
main();
