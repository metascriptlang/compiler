// @stdout: early: caught Cannot access 'conf' before initialization
// @stdout: late: conf
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a callback stored before a class-typed const is declared, and fired before its declaration runs, throws the ReferenceError JS throws rather than reading nil; fired after, it reads the object.
class Conf { name: string = "conf"; }
const hooks: (() => string)[] = [];
hooks.push(() => conf.name);
function fire(): string { return hooks[0](); }
try { console.log(`early: ${fire()}`); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export const conf: Conf = new Conf();
console.log(`late: ${fire()}`);
