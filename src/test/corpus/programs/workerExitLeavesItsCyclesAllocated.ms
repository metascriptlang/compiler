// @xfail(raiser): the Raiser VM models no pool-thread root sets or worker exit, and runs the 50M-iteration busy loop past its VM iteration limit
// @skip-js: a sync main awaits the pool tasks, which the JS backend refuses; the program pins native worker threads
// @stdout: pairs 80 busy true
// @ledger-slack(Parent) 80
// @ledger-slack(Child) 80
// Pool tasks make cyclic garbage below the collection threshold while main stays busy, so the
// cells sit in the workers' root sets when the process ends. No other thread frees them: the SAN
// ledger shows all 80 of each still allocated (destroy=0; any destroy turns the slack red) and
// ASan reports nothing.
class Parent { child: Child | null = null; }
class Child { parent: Parent | null = null; }
function makePairs(n: int32): int32 {
	for (let i: int32 = 0; i < n; i += 1) {
		const p = new Parent();
		const c = new Child();
		p.child = c;
		c.parent = p;
	}
	return n;
}
function busy(n: int32): int32 {
	let s: int32 = 0;
	for (let i: int32 = 0; i < n; i += 1) s = (s * 31 + i) % 1000003;
	return s;
}
function main(): void {
	const hs: Promise<int32>[] = [];
	for (let k: int32 = 0; k < 8; k += 1) hs.push(spawn(() => makePairs(10)));
	const b = busy(50000000);
	let total: int32 = 0;
	for (const h of hs) total += await h;
	console.log(`pairs ${total} busy ${b > -1}`);
}
main();
