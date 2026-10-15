// @stdout: object|object|object|object|string|9 1
// note: `typeof` only reads a union operand, whichever position takes its result: a module const, an array push, a return. The last two values are the control: one object of each type destroyed through a plain read, so the SAN ledger compares each type rather than taking a type with no destroy for one without a destroy routine.

class Box { a: number = 1; }

const on = true;
const held = on ? { a: 1 } : 0;
const atModule = typeof held;

function pushed(c: boolean): string {
	const out: string[] = [];
	const p = c ? { a: 2 } : 0;
	out.push(typeof p);
	return out[0];
}

function returned(c: boolean): string {
	const p = c ? { a: 3 } : 0;
	return typeof p;
}

function returnedClass(c: boolean): string {
	const p: Box | string = c ? new Box() : "s";
	return typeof p;
}

function control(): string {
	const plain = { a: 9 };
	const box = new Box();
	return `${plain.a} ${box.a}`;
}

console.log(`${atModule}|${pushed(true)}|${returned(true)}|${returnedClass(true)}|${returnedClass(false)}|${control()}`);
