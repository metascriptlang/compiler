// @stdout: early: caught Cannot access 'counter' before initialization
// @stdout: late: 6
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a let assigned from a function before its declaration runs throws the ReferenceError JS throws and leaves the binding to its initializer; the same write after the declaration lands.
function bump(): void { counter = counter + 5; }
function reset(): void { counter = 5; }
try { reset(); console.log("early: wrote"); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export let counter: number = Math.floor(1.5);
bump();
console.log(`late: ${counter}`);
