// @stdout: top 2
// @stdout: one 1
// @stdout: fn 3
// @stdout: stmt done
// @stdout: mixed 2 7
// @exit: 0

const top = await Promise.all([spawn(() => {}), spawn(() => {})]);
console.log("top", top.length);

const one = await Promise.all([spawn(() => {})]);
console.log("one", one.length);

async function inFn(): Promise<number> {
	const r = await Promise.all([spawn(() => {}), spawn(() => {}), spawn(() => {})]);
	return r.length;
}
console.log("fn", await inFn());

await Promise.all([spawn(() => {}), spawn(() => {})]);
console.log("stmt done");

const mixed = await Promise.all([spawn(() => 7), spawn(() => 8)]);
console.log("mixed", mixed.length, mixed[0]);
