// @stdout: object 7
// @stdout: rebound 9
// @stdout: array 22
// @stdout: nested root
// @stdout: deeper 42
// @stdout: generic 4 s
// @stdout: nullable 5
// A function stored in an object or array literal may read the binding that
// literal initializes: it cannot run before the binding holds the literal, so
// it reads the binding's current value whenever it is called. A `let` rebound
// later is read at its new value, which shows the closure holds the binding
// and not a copy taken while the literal was built.

interface Box {
	read: () => int32;
	value: int32;
}

interface Tree {
	label: string;
	child: { up: () => string };
}

interface Cell<T> {
	get: () => T;
	value: T;
}

function boxed(): int32 {
	const box: Box = { read: (): int32 => box.value, value: 7 };
	return box.read();
}

function rebound(): int32 {
	let box: Box = { read: (): int32 => box.value, value: 1 };
	const first = box.read;
	box = { read: (): int32 => 0, value: 9 };
	return first();
}

function listed(): int32 {
	const fs: (() => int32)[] = [(): int32 => fs.length, (): int32 => fs.length * 10];
	return fs[0]() + fs[1]();
}

function nested(): string {
	const n: Tree = { label: "root", child: { up: (): string => n.label } };
	return n.child.up();
}

function deeper(): int32 {
	const box: Box = {
		read: (): int32 => {
			const twice = (): int32 => box.value * 2;
			return twice();
		},
		value: 21,
	};
	return box.read();
}

function cell<T>(v: T): string {
	const c: Cell<T> = { get: (): T => c.value, value: v };
	return `${c.get()}`;
}

function nullable(): int32 {
	const box: Box | null = { read: (): int32 => box!.value, value: 5 };
	return box!.read();
}

console.log("object " + boxed().toString());
console.log("rebound " + rebound().toString());
console.log("array " + listed().toString());
console.log("nested " + nested());
console.log("deeper " + deeper().toString());
console.log("generic " + cell<int32>(4) + " " + cell<string>("s"));
console.log("nullable " + nullable().toString());
