const all: ((n: int32) => void)[] = [];

function remember(f: (n: int32) => void): void {
	all.push(f);
}

class Listener {
	visit: (n: int32) => void = (n: int32): void => {};
}

let owner: Listener | null = null;

@wasm
export function listen(visit: (n: int32) => void): void {
	remember(visit);
}

@wasm
export function adopt(visit: (n: int32) => void): void {
	const l = new Listener();
	l.visit = visit;
	owner = l;
}

@wasm
export function fire(n: int32): int32 {
	for (const f of all) f(n);
	const o = owner;
	if (o != null) o.visit(n + 100);
	return all.length;
}

@wasm
export function clear(): void {
	while (all.length > 0) all.pop();
	owner = null;
}
