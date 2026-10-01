let count: int32 = 600;
let memo: string = "ignored";

export function version(): int32 { return 3; }
export function bump(): void {
	count += 1;
	memo += "!";
}
export function snapshot(): string {
	return `${count} ${memo}`;
}
