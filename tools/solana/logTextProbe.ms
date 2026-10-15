import { instructionData, logText, logU64, logPubkey, logData, programId } from "std/solana";

function main(): void {
	const d = instructionData();
	const o = d.readU8(0);
	if (!o.ok) { return; }
	const rest = d.range(1, d.length - 1);
	if (!rest.ok) { return; }
	if (o.value == 0) { }
	if (o.value == 1) { logText("hello"); }
	if (o.value == 2) { logText(rest.value); }
	if (o.value == 3) { logU64(7); }
	if (o.value == 4) { logPubkey(programId()); }
	if (o.value == 5) { logData(rest.value); }
	if (o.value == 6) { const n = rest.value.length; logText(`n=${n}`); }
}
main();
