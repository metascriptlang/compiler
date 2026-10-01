let count: int64 = 20000;
let memo: int32 = 30000;
let ephemeral: int32 = 70000;
let newcomer: int32 = 80000;
let label: string = "ignored";
let broken: int32 = 900;
let brokenText: string = "ready";

export function version(): int32 { return 8; }
export function bump(): void { count += 1; }
export function snapshot(): string {
	return `${count} ${memo} ${ephemeral} ${newcomer} ${label} ${broken} ${brokenText}`;
}
