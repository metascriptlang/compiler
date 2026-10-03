let count: int64 = 0;

function hidden(): int32 {
	return 2000 + version();
}

export function version(): int32 {
	return 3;
}

export function tick(): int32 {
	count += 100;
	return 0;
}

export function snapshot(): string {
	return `${count}`;
}

export function localHandler(): () => int32 {
	return hidden;
}

export function makeAdder(base: int32): (x: int32) => int32 {
	return (x: int32): int32 => x + base * 2 + version();
}
