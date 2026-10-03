// @stdout: null null null null null | box null box box | null null
class Box { v: int32 = 0; }

function show(b: Box | null): string { return b == null ? "null" : "box"; }

function viaLocal(flag: boolean, b: Box | null): string {
	const x: Box | null = flag ? null : b;
	return show(x);
}

function viaReturn(flag: boolean, b: Box | null): Box | null {
	return flag ? null : b;
}

function viaArg(flag: boolean, b: Box | null): string {
	return show(flag ? null : b);
}

function swapped(flag: boolean, b: Box | null): string {
	return show(flag ? b : null);
}

function inferred(flag: boolean, b: Box | null): string {
	const x = flag ? null : b;
	return show(x);
}

function strShow(s: string | null): string { return s == null ? "null" : s; }

function strViaArg(flag: boolean, s: string): string {
	return strShow(flag ? null : s);
}

function strSwapped(flag: boolean, s: string): string {
	return strShow(flag ? s : null);
}

function twoArgs(tag: string, b: Box | null): string {
	return tag + " " + show(b);
}

function run(): void {
	const bx = new Box();
	const a = `${viaLocal(true, bx)} ${show(viaReturn(true, bx))} ${viaArg(true, bx)} ${swapped(false, bx)} ${inferred(true, bx)}`;
	const b = `${twoArgs("box", true ? null : bx)} ${twoArgs("box", false ? null : bx)}`;
	const c = `${strViaArg(true, "s")} ${strSwapped(false, "s")}`;
	console.log(`${a} | ${b} | ${c}`);
}

run();
