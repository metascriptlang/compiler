// @stdout: 0
// @stdout: 3 3 3 ab ab
// @stdout: 8232 8233

let calls = 0;
function touch(): void { calls += 1; }
function skippedLs(): void { return touch(); }
function skippedPs(): void { return touch(); }

const rawLs = "a b";
const rawPs = "a b";
const rawTemplate = `a b`;
const continuedLs = "a\ b";
const continuedPs = `a\ b`;

skippedLs();
skippedPs();
console.log(calls);
console.log(rawLs.length, rawPs.length, rawTemplate.length, continuedLs, continuedPs);
console.log(rawLs.charCodeAt(1), rawPs.charCodeAt(1));
