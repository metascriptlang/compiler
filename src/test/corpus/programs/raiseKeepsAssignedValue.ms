// @stdout: 1 7 1 1 3 5 1 5 3 1 v1
// @stdout: 7 7 4
// note: a call that raises leaves the location it was assigned to untouched: a local, a global, a field of an object, an element of an array, a struct with and without a string field, the call inside a larger value or a compound assignment, inside a try and, for a global, from a function the raise leaves; a call that returns is stored as before. Same output on every lane.
struct Big { n: int64; pad1: int64; pad2: int64; pad3: int64; }
struct Named { n: int64; s: string; }
class Holder { k: int32 = 5; big: Big = { n: 5, pad1: 0, pad2: 0, pad3: 0 }; }
let g: int32 = 7;
let gb: Big = { n: 7, pad1: 0, pad2: 0, pad3: 0 };

function mk(n: int32): int32 {
	if (n < 0) { throw new Error("neg"); }
	return n;
}
function mkb(n: int64): Big {
	if (n < 0) { throw new Error("neg"); }
	return { n: n, pad1: 0, pad2: 0, pad3: 0 };
}
function mkn(n: int64): Named {
	if (n < 0) { throw new Error("neg"); }
	return { n: n, s: "v" + n.toString() };
}
function setGlobal(): void { g = mk(-1); }
function setGlobalBig(): void { gb = mkb(-1); }

function main(): void {
	let a = mk(1);
	let c = mk(1);
	let d = mk(1);
	let m = mk(3);
	let b = mkb(1);
	let named = mkn(1);
	const h = new Holder();
	const arr: int32[] = [3];
	try { a = mk(-1); } catch (e) { }
	try { g = mk(-1); } catch (e) { }
	try { c = mk(-1) + 1; } catch (e) { }
	try { d += mk(-1); } catch (e) { }
	try { m *= mk(-1); } catch (e) { }
	try { h.k = mk(-1); } catch (e) { }
	try { b = mkb(-1); } catch (e) { }
	try { h.big = mkb(-1); } catch (e) { }
	try { arr[0] = mk(-1); } catch (e) { }
	try { named = mkn(-1); } catch (e) { }
	console.log(`${a} ${g} ${c} ${d} ${m} ${h.k} ${b.n} ${h.big.n} ${arr[0]} ${named.n} ${named.s}`);
	try { setGlobal(); } catch (e) { }
	try { setGlobalBig(); } catch (e) { }
	try { b = mkb(4); } catch (e) { }
	console.log(`${g} ${gb.n} ${b.n}`);
}
main();
