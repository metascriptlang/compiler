// @stdout: 3 3 3 2 12 12 2.5 6 3
// note: a call that raises leaves the target of a compound assignment untouched whichever checked helper the operator lowers to: `*=` on a local, a field, an element and an int8, `**=`, `/=`, `%=`, a float `%=` and a number `&=`. Same output on every lane.
class Holder { k: int32 = 3; }

function mk(n: int32): int32 {
	if (n < 0) { throw new Error("neg"); }
	return n;
}
function mk8(n: int8): int8 {
	if (n < 0) { throw new Error("neg"); }
	return n;
}
function mkf(n: number): number {
	if (n < 0) { throw new Error("neg"); }
	return n;
}

function main(): void {
	let m = mk(3);
	const h = new Holder();
	const arr: int32[] = [3];
	let p = mk(2);
	let q = mk(12);
	let r = mk(12);
	let f: number = 2.5;
	let bits: number = 6;
	let s: int8 = mk8(3);
	try { m *= mk(-1); } catch (e) { }
	try { h.k *= mk(-1); } catch (e) { }
	try { arr[0] *= mk(-1); } catch (e) { }
	try { p **= mk(-1); } catch (e) { }
	try { q /= mk(-1); } catch (e) { }
	try { r %= mk(-1); } catch (e) { }
	try { f %= mkf(-1); } catch (e) { }
	try { bits &= mkf(-1); } catch (e) { }
	try { s *= mk8(-1); } catch (e) { }
	console.log(`${m} ${h.k} ${arr[0]} ${p} ${q} ${r} ${f} ${bits} ${s}`);
}
main();
