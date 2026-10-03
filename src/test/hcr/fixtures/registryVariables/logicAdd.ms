let count: int32 = 500;
let memo: string = "replacement";
let ephemeral: int32 = 1000;
let newcomer: int32 = 20;
let label: string = "new";

export function version(): int32 { return 2; }
export function bump(): void {
	count += 1;
	memo += "!";
	ephemeral += 1;
	newcomer += 1;
	label += "!";
}
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral} ${newcomer} ${label}`;
}
