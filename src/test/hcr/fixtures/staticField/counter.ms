export class Counter {
	static readonly LIMIT: int32 = 7;
	static readonly label: string = "c";
	static total: int32 = 5;
	static computed: int32 = seed();
}

function seed(): int32 {
	return 40 + 2;
}

export function limit(): int32 {
	return Counter.LIMIT;
}

export function bump(): int32 {
	Counter.total += 1;
	return Counter.total;
}
