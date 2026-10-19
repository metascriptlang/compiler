// @stdout: early: caught Cannot access 'box' before initialization
// @stdout: late: 7
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a class-typed let read through a field before its declaration runs throws the ReferenceError JS throws, never a nil dereference.
class Box { v: int32 = 7; }
function peek(): int32 { return box.v; }
try { console.log(`early: ${peek()}`); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export let box: Box = new Box();
console.log(`late: ${peek()}`);
