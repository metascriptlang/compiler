import { account, accountCount, instructionData, logU64 } from "std/solana";

function main(): void {
	const counted = accountCount();
	logU64(counted as uint64);
	const last = account(counted - 1);
	logU64(last.ok ? last.value.key().bytes[0] as uint64 : 999);
	logU64(account(counted).ok ? 1 : 0);
	const data = instructionData();
	logU64(data.length as uint64);
	const first = data.readU8(0);
	logU64(first.ok ? first.value as uint64 : 999);
}
main();
