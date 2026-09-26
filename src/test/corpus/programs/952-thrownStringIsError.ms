// @xfail(raiser): the Raiser bytecode compiler keeps a thrown string a string, so e.message fails (expected an object, got value kind String), also on the baseline
// @stdout: m=x|m=b|m=z|re=x
// note: a thrown string, or a string-literal union, is caught as an Error whose message is the string (C did not compile the union, JS printed m=undefined).

type Lit = "a" | "b";

function plain(): void { throw "x"; }
function lit(l: Lit): void { throw l; }
function error(): void { throw new Error("z"); }

function run(): void {
	try { plain(); } catch (e) { console.log("m=" + e.message); }
	try { lit("b"); } catch (e) { console.log("m=" + e.message); }
	try { error(); } catch (e) { console.log("m=" + e.message); }
	try {
		try { plain(); } catch (e) { throw e; }
	} catch (e2) {
		console.log("re=" + e2.message);
	}
}
run();
