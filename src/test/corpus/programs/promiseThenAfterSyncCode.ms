// @stdout: 1 sync start
// @stdout: 2 sync end
// @stdout: 3 then 5
// @stdout: 4 timeout
// @xfail(raiser): raiser runtime error: Unknown host function: msFutureThen
// @xfail(c): a `.then` registered before the dispatcher exists runs at registration (PARALOCK-runtime Amendment P rule 1, not landed)
// @xfail(orc): a `.then` registered before the dispatcher exists runs at registration (PARALOCK-runtime Amendment P rule 1, not landed)
// @xfail(danger): a `.then` registered before the dispatcher exists runs at registration (PARALOCK-runtime Amendment P rule 1, not landed)
// note: a `.then` on a settled promise runs after the synchronous code that registered it and before a 0 ms timer, as in TypeScript.

console.log("1 sync start");
const p: Promise<number> = Promise.resolve(5 as number);
p.then((v: number): void => { console.log("3 then " + v.toString()); });
setTimeout((): void => { console.log("4 timeout"); }, 0);
console.log("2 sync end");
