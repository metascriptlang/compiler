// @stdout: a!|n?|x1!
let g: string = "a";
class W { name: string = "n"; }
const w = new W();
function setG(): string { g = "zz"; return "!"; }
function setN(): string { w.name = "zz"; return "?"; }
function viaLocal(): string {
	const v = new W();
	v.name = "x1";
	const set = (): string => { v.name = "zz"; return "!"; };
	v.name += set();
	return v.name;
}
g += setG();
w.name += setN();
console.log(`${g}|${w.name}|${viaLocal()}`);
