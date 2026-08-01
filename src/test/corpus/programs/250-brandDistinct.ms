// note: TSGAP item 5 S1 — branded primitives: nominal in the checker, erased
// at runtime; pins the erased behavior through every lane (guard bug074).
type OrderId = string & { __brand: "OrderId" };
type ScoreTag = int32 & { __brand: "Score" };

function fmtOrder(id: OrderId): string {
	return "order:" + (id as string);
}

function main(): void {
	const a: OrderId = "A-1" as OrderId;
	console.log(fmtOrder(a));
	console.log(a.length);
	const b: OrderId = "A-1" as OrderId;
	if (a === b) { console.log("same"); }
	const s: ScoreTag = 41 as ScoreTag;
	console.log((s as int32) + 1);
}
main();
