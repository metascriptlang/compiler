let count: int32 = 0;

function hidden(): int32 {
	return 1000 + version();
}

export function version(): int32 {
	return 1;
}

export function tick(): int32 {
	count += 1;
	return count;
}

export function snapshot(): string {
	return `${count}`;
}

export function localHandler(): () => int32 {
	return hidden;
}

export function makeAdder(base: int32): (x: int32) => int32 {
	return (x: int32): int32 => x + base + version();
}
