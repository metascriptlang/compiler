// @stdout: early: caught Cannot access 'limit' before initialization
// @stdout: late: 43
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a module const read two calls deep before its declaration runs throws the ReferenceError JS throws, on every lane; after the declaration the same call reads the value.
function inner(): number { return limit * 2; }
function outer(): number { return inner() + 1; }
try { console.log(`early: ${outer()}`); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export const limit: number = Math.floor(21.5);
console.log(`late: ${outer()}`);
