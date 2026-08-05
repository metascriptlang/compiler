// @stdout: ternary-shortcircuit effects=[EVAL T]
//
// ternary-shortcircuit — C↔JS parity guard for `?:` conditional evaluation in
// sub-expression positions (call-argument, string-concat operand). Sibling of
// 210-condNrvo, which covers arms holding NRVO/object construction; here the
// arm's only hazard is a plain raise-checked call — on C every call emits an
// `if (msErr) goto` statement, so it cannot sit inside a C `?:`. An untaken
// arm that runs poisons `effects` via loud(); the null-guard idiom must not
// crash on the untaken `p.name` deref. JS's native ternary is the spec.

interface P { name: string; }

let effects: string = "";

function loud(tag: string): string {
	effects = effects + "[EVAL " + tag + "]";
	return tag;
}

function main(): void {
	const flags: int32[] = [1];
	const condT: boolean = flags[0] === 1;
	const condF: boolean = flags[0] === 2;

	console.log(condT ? "taken" : "x" + loud("A"));
	console.log("pre:" + (condT ? "yes" : "no" + loud("B")));
	console.log(condF ? "y" + loud("C") : "alt");
	console.log(condT ? "t-" + loud("T") : "alt2");

	console.log("ternary-shortcircuit effects=" + effects);

	const p: P = null as unknown as P;
	console.log(p !== null ? "has:" + p.name : "none");
}
main();
