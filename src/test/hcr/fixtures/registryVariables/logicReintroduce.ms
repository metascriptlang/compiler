let count: int32 = 700;
let memo: string = "ignored again";
let ephemeral: int32 = 70;
let newcomer: int32 = 80;
let label: string = "fresh";

export function version(): int32 { return 4; }
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
