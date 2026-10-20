// @stdout: 40 40 15 2
// note: a program that makes and drops strings, arrays, objects and boxes must leave every heap item accounted for by its holders when it ends, and so must the strand that runs a spawned closure. The Raiser VM audits the live items outside --danger and fails the run when a count disagrees with its holders, so the program's own output is the proof the audit stayed quiet.

class Link { next: Link | null = null; label: string = ""; }

function churn(n: number): number {
	let len = 0;
	let last: string | number = 0;
	for (let i = 0; i < n; i++) {
		const s = "k" + i;
		const a = [s, s + "x"];
		const o = new Link();
		o.label = a[1];
		o.next = new Link();
		o.next.label = s;
		last = i % 2 == 0 ? s : i;
		len += o.label.length + o.next.label.length;
	}
	return len + (typeof last == "string" ? last.length : 0);
}

const direct = churn(8);
const viaStrand = await spawn(() => churn(8));
let boxed: number | null = null;
for (let i = 0; i < 6; i++) { boxed = (boxed == null ? 0 : boxed) + i; }
const kept: string[] = [];
for (let i = 0; i < 5; i++) { kept.push("s" + i); }
kept.pop();
kept.shift();
kept.splice(1, 1, kept[0]);
console.log(`${direct} ${viaStrand} ${boxed} ${kept.length - 1}`);
