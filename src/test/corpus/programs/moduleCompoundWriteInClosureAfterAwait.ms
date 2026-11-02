// @stdout: tdz
// @stdout: tdz
// @stdout: ab 3
// note: A compound write to a module binding declared after a top-level await sits behind the binding's init flag. A string append lowers to a call, so the guard must wrap the whole statement, not turn it into a conditional expression, which the Raiser cannot lower.

function early(): void {
	tail += "z";
}

function earlyCount(): void {
	count += 1;
}

try { early(); } catch (e) { console.log("tdz"); }
try { earlyCount(); } catch (e) { console.log("tdz"); }

let head = "";
await sleepAsync(0).then((): void => { head += "a"; });
let tail = "";
let count = 0;
await sleepAsync(0).then((): void => { tail += "b"; count += 3; });
console.log(`${head}${tail} ${count}`);
