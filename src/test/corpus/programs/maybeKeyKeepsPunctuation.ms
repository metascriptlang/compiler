// @stdout: 1 x 2 | 3 y 4
// @stdout: a-b a.b | c-d e-f e.f
// note: a nullable payload whose type key differs from another only in punctuation is its own Maybe type; the Maybe key once dropped every non-alphanumeric character, so `[int32, [string, int32]] | null` and `[int32, [string], int32] | null`, or `"a-b" | null` and `"a.b" | null`, shared one Maybe and the second was refused against the first.
function main(): void {
	const p: [int32, [string, int32]] | null = [1, ["x", 2]];
	const t: [int32, [string], int32] | null = [3, ["y"], 4];
	if (p != null && t != null) console.log(`${p[0]} ${p[1][0]} ${p[1][1]} | ${t[0]} ${t[1][0]} ${t[2]}`);
	const dash: "a-b" | null = "a-b";
	const dot: "a.b" | null = "a.b";
	const dashes: "c-d" | "e.f" | null = "c-d";
	const dots: "c.d" | "e-f" | null = "e-f";
	const dotsAgain: "c.d" | "e.f" | null = "e.f";
	if (dash != null && dot != null && dashes != null && dots != null && dotsAgain != null) console.log(`${dash} ${dot} | ${dashes} ${dots} ${dotsAgain}`);
}
main();
