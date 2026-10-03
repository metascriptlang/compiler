let count: int64 = 200;
let memo: int32 = 300;
let ephemeral: int32 = 700;
let newcomer: int32 = 800;
let label: string = "ignored";

export function version(): int32 { return 5; }
export function bump(): void {
	count += 1;
	memo += 1;
}
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral} ${newcomer} ${label}`;
}
