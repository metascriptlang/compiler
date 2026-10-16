let count: int32 = 5;
probe();
let later: int32 = 7;

function probe(): void {
	try {
		console.log(`HCR-TDZ early: ${later}`);
	} catch (e) {
		console.log(`HCR-TDZ early: ${(e as Error).message}`);
	}
}

export function version(): int32 { return 1; }
export function bump(): void {
	count += 1;
	later += 1;
}
export function snapshot(): string {
	return `${count} ${later}`;
}
