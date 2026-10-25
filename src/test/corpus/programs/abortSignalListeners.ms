// @stdout: a aborted=true reason=why
// @exit: 0
// note: an AbortSignal abort listener, as the DOM one: added once however often it is added, removable, run once at the first abort and never for another event type

const c = new AbortController();
const log: string[] = [];
const a = (): void => { log.push("a"); };
const b = (): void => { log.push("b"); };
c.signal.addEventListener("abort", a);
c.signal.addEventListener("abort", b);
c.signal.addEventListener("abort", a);
c.signal.addEventListener("other", b);
c.signal.removeEventListener("abort", b);
c.abort("why");
c.abort("again");
console.log(`${log.join(",")} aborted=${c.signal.aborted} reason=${c.signal.reason}`);
