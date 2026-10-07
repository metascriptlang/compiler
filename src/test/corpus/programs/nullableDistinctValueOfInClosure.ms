// @stdout: x|y|none
type Accessor<T> = distinct (() => T);

function accessor<T>(f: () => T): Accessor<T> {
	return f as Accessor<T>;
}

function valueOf<T>(this a: Accessor<T>): T {
	return (a as () => T)();
}

function run(f: () => string): string {
	return f();
}

function bound(o: Accessor<string> | null): string {
	if (o !== null) {
		return run(() => (o as () => string)());
	}
	return "none";
}

interface Props { label?: Accessor<string> | null; }

function viaField(p: Props): string {
	const o = p.label;
	if (o !== null) return run(() => (o as () => string)());
	return "none";
}

console.log(bound(accessor(() => "x")) + "|" + viaField({ label: accessor(() => "y") }) + "|" + bound(null));
