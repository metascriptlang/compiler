// note: An async function can return a closure: the closure keeps its captured environment through the future, on every lane, and a loop of such awaits releases each environment.

type Count = () => int32;
type Label = () => string;

async function counter(start: int32): Promise<Count> {
	let seen = start;
	return (): int32 => { seen = seen + 1; return seen; };
}

async function labeled(tag: string): Promise<Label> {
	const owned = tag + "-env";
	return (): string => owned;
}

async function constant(): Promise<Count> {
	return (): int32 => 7;
}

async function sumTwice(start: int32): Promise<int32> {
	const f = await counter(start);
	return f() + f();
}

const c = await counter(10);
const l = await labeled("top");
const k = await constant();
console.log(`top ${c()} ${c()} ${l()} ${k()}`);
console.log(`resume ${await sumTwice(20)}`);

let acc = 0;
for (let i = 0; i < 20000; i = i + 1) {
	const g = await labeled("loop");
	acc = acc + g().length;
}
console.log(`loop acc=${acc}`);
