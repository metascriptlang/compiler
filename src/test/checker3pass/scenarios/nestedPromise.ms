import { checkOnly } from "../helpers";

const NESTED = "promise of a promise";

test "a promise of a promise is refused where it is written" {
	const text = checkOnly(`
type P = Promise<number>;
async function wrap(): Promise<Promise<number>> { return 1; }
function hold(p: Promise<P>): void {}
`).errors.join("\n");
	assert text.contains("'Promise<Promise<number>>' is a " + NESTED + ", which is refused: write 'Promise<number>'"), text;
	let count = 0;
	for (const line of text.split("\n")) if (line.contains("is a " + NESTED)) count += 1;
	assert count == 2, "the return annotation and the aliased parameter: " + text;
}

test "spawning a function that returns a promise is refused with the rewrite" {
	const text = checkOnly(`
async function work(): Promise<number> { return 41; }
function mk(): Promise<number> { return work(); }
async function main(): Promise<void> {
	const a = await spawn(work);
	const b = await spawn(mk);
	const c = await spawn(() => work());
}
`).errors.join("\n");
	assert text.contains("write 'await work()', or 'await spawn(() => workSync())'"), text;
	assert text.contains("write 'await mk()'"), text;
	assert text.contains("await the promise the function returns instead of spawning it"), text;
}

test "an async body that returns a promise is refused; returning its awaited value is not" {
	const result = checkOnly(`
async function work(): Promise<number> { return 41; }
async function wrap() { return work(); }
const arrowWrap = async () => { return work(); };
async function fine() { return await work(); }
function workSync(): number { return 41; }
async function main(): Promise<void> {
	const a = await fine();
	const b = await spawn(() => workSync());
	const c = await work();
}
`);
	const text = result.errors.join("\n");
	assert text.contains("async function 'wrap' returns 'Promise<number>' from its body, which makes a " + NESTED), text;
	assert text.contains("an async arrow function returns 'Promise<number>'"), text;
	assert result.errors.length == 2, "only the two promise-returning bodies: " + text;
}
