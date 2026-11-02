// @stdout: a b a 1 nested-x nested-n done
const out: string[] = [];
function log(s: string): void {
	out.push(s);
}
let hits = 0;
function bump(): void {
	hits += 1;
}
for (const c of [true, false, true]) {
	c ? log("a") : log("b");
}
for (let i = 0; i < 2; i += 1) {
	i == 0 ? bump() : log(String(hits));
}
function nested(c: boolean, d: boolean): void {
	c ? (d ? log("nested-x") : log("nested-y")) : log("nested-n");
}
nested(true, true);
nested(false, true);
log("done");
console.log(out.join(" "));
