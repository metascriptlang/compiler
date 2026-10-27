// @stdout: inside 3
// @stdout: 4 5 a1 6 8
// note: a parameter spelled like a runtime C name (`msPrintln`, `msString`) is its own variable in the function, as a local of that spelling already was; it used to shadow the runtime symbol the body calls.
function f(msPrintln: number): number {
	console.log("inside", msPrintln);
	return msPrintln + 1;
}
function g(msString: number): number { return msString + 1; }
const h = (msPrintln: number, msString: string): string => `${msString}${msPrintln}`;
class K {
	m(msPrintln: number): number { return msPrintln * 2; }
}
console.log(`${f(3)} ${g(4)} ${h(1, "a")} ${g(5)} ${new K().m(4)}`);
