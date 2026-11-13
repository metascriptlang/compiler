// @stdout: early: caught Cannot access 'NAMES' before initialization
// @stdout: late: 3 13
// @stdout: counter: 1 2 3
// @stdout: nested: 9
// @xfail(js): node names the binding by its mangled JS name in the ReferenceError message (inbox 2026-10-16-js-tdz-message-names-the-mangled-binding)
// note: a loop reading a module const before its declaration runs throws on every iteration path, and after it reads the value; a const object's field written inside the loop is what the next iteration reads.
class Counter { n: int32 = 0; }

function scan(): string {
	let count = 0;
	let chars = 0;
	for (const name of NAMES) {
		count += 1;
		chars += name.length;
	}
	return `${count} ${chars}`;
}

function bump(): string {
	let out = "";
	for (let i = 0; i < 3; i += 1) {
		COUNTER.n += 1;
		out = out + " " + COUNTER.n.toString();
	}
	return out;
}

function nested(): int32 {
	let total: int32 = 0;
	for (const a of NAMES) {
		for (const b of NAMES) total += 1;
	}
	return total;
}

try { console.log(`early: ${scan()}`); } catch (e) { console.log(`early: caught ${(e as Error).message}`); }
export const NAMES: Readonly<string[]> = ["http", "ftp", "mailto"];
const COUNTER = new Counter();
console.log(`late: ${scan()}`);
console.log(`counter:${bump()}`);
console.log(`nested: ${nested()}`);
