// Parity program — a binding that shadows a captured name inside a nested
// block, an if-block, or a nested arrow body keeps its own storage. Lambda
// lifting is a C-backend pass, so the JS lane is the oracle: it reads every
// binding directly and cannot express the defect.

type NestedThunk = () => int32;

function blockShadowInLoop(): string {
	const fns: NestedThunk[] = [];
	const seen: int32[] = [];
	for (let i = 0; i < 3; i += 1) {
		let x = 100 + i;
		fns.push(() => x);
		{
			let x = 900 + i;
			seen.push(x);
			x = x + 1;
			seen.push(x);
		}
	}
	let out = "";
	for (const v of seen) { out = out + v.toString() + ","; }
	out = out + "|";
	for (const f of fns) { out = out + f().toString() + ","; }
	return out;
}

function blockShadowNoLoop(): string {
	let x = 100;
	const f = () => x;
	let got = "";
	{
		let x = 900;
		got = got + x.toString() + ",";
		x = x + 1;
		got = got + x.toString() + ",";
	}
	return got + "cap=" + f().toString();
}

function shadowInNestedArrow(): string {
	let b = 50;
	const fb = () => b;
	const inner = (): int32 => { let b = 700; return b; };
	return inner().toString() + "," + fb().toString();
}

function shadowInIfBlock(): string {
	let a = 100;
	const fa = () => a;
	let got = 0;
	if (a > 0) { let a = 900; got = a; }
	return got.toString() + "," + fa().toString();
}

function shadowChainThreeDeep(): string {
	let v = 1;
	const f1 = () => v;
	let acc = "";
	{
		let v = 2;
		const f2 = () => v;
		{
			let v = 3;
			const f3 = () => v;
			acc = acc + f3().toString();
		}
		acc = acc + f2().toString();
	}
	return acc + f1().toString();
}

function shadowReusedAcrossSiblingBlocks(): string {
	let s = "outer";
	const fs = () => s;
	let acc = "";
	{ let s = "left"; acc = acc + s; }
	{ let s = "right"; acc = acc + s; }
	return acc + "|" + fs();
}

function shadowWithoutCapture(): string {
	let out = "";
	for (let i = 0; i < 2; i += 1) {
		let x = 100 + i;
		{
			let x = 900 + i;
			out = out + x.toString() + ",";
		}
		out = out + x.toString() + ",";
	}
	return out;
}

function main(): void {
	console.log("blockShadowInLoop=" + blockShadowInLoop());
	console.log("blockShadowNoLoop=" + blockShadowNoLoop());
	console.log("shadowInNestedArrow=" + shadowInNestedArrow());
	console.log("shadowInIfBlock=" + shadowInIfBlock());
	console.log("shadowChainThreeDeep=" + shadowChainThreeDeep());
	console.log("shadowReusedAcrossSiblingBlocks=" + shadowReusedAcrossSiblingBlocks());
	console.log("shadowWithoutCapture=" + shadowWithoutCapture());
}
main();
