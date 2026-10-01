let count: int32 = 5;
let memo: string = "seed";
let ephemeral: int32 = 10;

export function version(): int32 { return 1; }
export function bump(): void {
	count += 1;
	memo += "!";
	ephemeral += 1;
}
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral}`;
}
