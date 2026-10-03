let count: int64 = 2000;
let memo: int32 = 3000;
let ephemeral: int32 = 7000;
let newcomer: int32 = 8000;
let label: string = "ignored";
let broken: int32 = fail();

function fail(): int32 {
	count += 7;
	memo += 11;
	throw new Error("integer initializer failed");
}
export function version(): int32 { return 6; }
export function bump(): void { count += 100; }
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral} ${newcomer} ${label} ${broken}`;
}
