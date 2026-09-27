// @stdout: m=x|m=b|m=z|re=x|lit=a
// note: a thrown string, or a string-literal union, is caught as an Error whose message is the string (C did not compile the union, JS printed m=undefined). The checker boxes it into `new Error(s)`, so a union parameter reaches the string parameter of Error's constructor and is passed by value on C.

type Lit = "a" | "b";

function plain(): void { throw "x"; }
function lit(l: Lit): void { throw l; }
function error(): void { throw new Error("z"); }
function boxed(l: Lit): void { throw new Error(l); }

function run(): string {
	const out: string[] = [];
	try { plain(); } catch (e) { out.push("m=" + e.message); }
	try { lit("b"); } catch (e) { out.push("m=" + e.message); }
	try { error(); } catch (e) { out.push("m=" + e.message); }
	try {
		try { plain(); } catch (e) { throw e; }
	} catch (e2) {
		out.push("re=" + e2.message);
	}
	try { boxed("a"); } catch (e) { out.push("lit=" + e.message); }
	return out.join("|");
}
console.log(run());
