// @stdout: true false true true true|P,Q,T,A,S,|a,P,b,|skipped:|taken:P,S,Q,|3 false true true true true true true|calls=1[]
// note: a value that is never null still evaluates its operand once, in source order, when compared with `null`: a struct, a string, a tuple and a fixed array returned by a call, a call to the left of the comparison, the arms of `&&`, `||` and `?:` that skip it, and the bound operand of `??` on a string. Same output on every backend.

struct P { x: int32; }
struct Q { name: string; n: int32; }

let trace = "";
function tr(label: string): void { trace = trace + label + ","; }
function note(label: string): int32 { tr(label); return 1; }
function makeP(): P { tr("P"); return { x: 1 }; }
function makeQ(): Q { tr("Q"); return { name: "nm", n: 2 }; }
function makeS(): string { tr("S"); return "s"; }
function makeT(): [int32, int32] { tr("T"); return [1, 2]; }
function makeA(): int32[3] { tr("A"); return [1, 2, 3]; }
function take(): string {
	const seen = trace;
	trace = "";
	return seen;
}

const isP = makeP() != null;
const isQ = makeQ() == null;
const isT = makeT() !== null;
const isA = makeA() != null;
const isS = null != makeS();
const kinds = `${isP} ${isQ} ${isT} ${isA} ${isS}`;
const kindsTrace = take();

const total = note("a") + (makeP() != null ? 1 : 0) + note("b");
const orderTrace = take();

const skippedAnd = false && makeP() != null;
const skippedOr = true || makeS() != null;
const skippedConditional = false ? makeQ() != null : true;
const skippedTrace = take();

const ranAnd = true && makeP() != null;
const ranOr = false || makeS() != null;
const ranConditional = true ? makeQ() != null : false;
const takenTrace = take();

const pure: P = { x: 3 };
const pureAnswer = pure != null && !(pure == null);

let calls = 0;
function counted(): string {
	calls = calls + 1;
	return "q".slice(1);
}
const once = counted() ?? "z";

const answers = `${total} ${skippedAnd} ${skippedOr} ${skippedConditional} ${ranAnd} ${ranOr} ${ranConditional} ${pureAnswer}`;
console.log(`${kinds}|${kindsTrace}|${orderTrace}|skipped:${skippedTrace}|taken:${takenTrace}|${answers}|calls=${calls}[${once}]`);
