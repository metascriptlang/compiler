// @stdout: ca1-xxx33 cgs-xxx33 qq

// a write inside try on a throw path, the borrow read in finally
function fresh(tag: string): string { return tag + "-" + "x".repeat(30); }
function replace(ref ys: string[]): void { ys = [fresh("n0"), fresh("n1")]; }
function setStr(ref s: string): void { s = fresh("qq"); }
function viaFinally(ref xs: string[]): string {
	const s = xs[1];
	let out = "";
	try {
		replace(xs);
		throw new Error("boom");
	} catch (e) {
		out = "c";
	} finally {
		out += s.substring(0, 6) + s.length.toString();
	}
	return out;
}
function strFinally(ref a: string): string {
	const t = a;
	let out = "";
	try {
		setStr(a);
		throw new Error("boom");
	} catch (e) {
		out = "c";
	} finally {
		out += t.substring(0, 6) + t.length.toString();
	}
	return out;
}
let g: string[] = [fresh("a0"), fresh("a1")];
const r2 = viaFinally(g);
let gs = fresh("gs");
const r3 = strFinally(gs);
console.log(`${r2} ${r3} ${gs.substring(0, 2)}`);
