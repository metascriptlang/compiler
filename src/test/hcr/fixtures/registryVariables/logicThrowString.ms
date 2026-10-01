let count: int64 = 2000;
let memo: int32 = 3000;
let ephemeral: int32 = 7000;
let newcomer: int32 = 8000;
let label: string = "ignored";
let brokenText: string = fail();

function fail(): string {
	count += 9;
	memo += 13;
	throw new Error("string initializer failed");
}
export function version(): int32 { return 7; }
export function bump(): void { count += 100; }
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral} ${newcomer} ${label} ${brokenText}`;
}
