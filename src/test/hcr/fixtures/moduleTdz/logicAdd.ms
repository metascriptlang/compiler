probe();
let count: int32 = 500;
let later: int32 = 700;
let added: int32 = 20;
class Tag {
	name(): string { return "tag"; }
}

function probe(): void {
	console.log("HCR-TDZ probe runs again");
}

export function version(): int32 { return 2; }
export function bump(): void {
	count += 1;
	later += 1;
	added += 1;
}
export function snapshot(): string {
	return `${count} ${later} ${added} ${new Tag().name()}`;
}
