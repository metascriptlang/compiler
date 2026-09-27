// @stdout: io cba xy
// note: a catch binding that shadows an outer catch binding is released under its own name (C released the outer exception twice and leaked the inner one).

function boom(m: string): void { throw new Error(m); }
function run(): string {
	let out = "";
	try { boom("o"); } catch (e) {
		try { boom("i"); } catch (e) { out = e.message; }
		out = out + e.message;
	}
	return out;
}
function deep(): string {
	let out = "";
	try { boom("a"); } catch (e) {
		try { boom("b"); } catch (e) {
			try { boom("c"); } catch (e) { out = e.message; }
			out = out + e.message;
		}
		out = out + e.message;
	}
	return out;
}
function sibling(): string {
	let out = "";
	try { boom("x"); } catch (e) { out = e.message; }
	try { boom("y"); } catch (e) { out = out + e.message; }
	return out;
}
console.log(run(), deep(), sibling());
