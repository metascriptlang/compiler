// @stdout: case body|deferred|arrow body|deferred arrow|default
let out = "";
function note(s: string): void { out = out + s; }
function each(xs: int32[], f: (x: int32) => void): void {
	for (const x of xs) f(x);
}
function onCase(k: int32): void {
	switch (k) {
		case 1:
			defer note("|deferred");
			note("case body");
			break;
		default:
			note("|default");
	}
}
function inArrow(): void {
	each([1], (x: int32): void => {
		defer note("|deferred arrow");
		note("|arrow body");
	});
}
onCase(1);
inArrow();
onCase(2);
console.log(out);
