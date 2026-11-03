const all: ((n: int32) => void)[] = [];

function remember(f: (n: int32) => void): void {
	all.push(f);
}

@wasm
export function listen(visit: (n: int32) => void): void {
	remember(visit);
}
