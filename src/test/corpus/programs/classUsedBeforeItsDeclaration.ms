// @stdout: early: caught Cannot access 'Late' before initialization
// @stdout: late: late
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: constructing a class from a function called before the class declaration runs throws the ReferenceError JS throws; after the declaration the same call constructs it.
function make(): string { return new Late().tag; }
try { console.log(`early: ${make()}`); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export class Late { tag: string = "late"; }
console.log(`late: ${make()}`);
