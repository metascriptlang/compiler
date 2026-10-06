// @stdout: splice-insert all-ok
// Parity program — the three-argument splice (delete then insert one item) on
// every element family: number[], string[], boolean[] (uint8 representation)
// and a ref interface array. Value elements compile through the typed
// msNumberArray/msStringArray/msUint8Array Splice3 helpers; the ref element
// keeps the msRefArraySplice3 void* path. Includes a string churn loop so the
// SAN lane exercises the stored-copy ownership of the string variant.

interface Box { id: number }

function dumpNum(label: string, arr: number[]): string {
	let s = label + "=[";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) s = s + ",";
		s = s + arr[i].toString();
	}
	return s + "]len=" + arr.length.toString();
}

function dumpStr(label: string, arr: string[]): string {
	let s = label + "=[";
	for (let i = 0; i < arr.length; i += 1) {
		if (i > 0) s = s + ",";
		s = s + arr[i];
	}
	return s + "]len=" + arr.length.toString();
}

function main(): void {
	const xs: number[] = [1, 2, 3];
	xs.splice(0, 0, 9);
	xs.splice(2, 1, 7);
	xs.splice(xs.length, 0, 5);
	xs.splice(1, 99, 0);
	console.log(dumpNum("num", xs));

	const head = "hello";
	const tail = "world";
	const ss: string[] = [head, tail];
	ss.splice(1, 1, head);
	console.log(dumpStr("str", ss) + " keep=" + head + "/" + tail);
	const one: string[] = ["x"];
	one.splice(0, 0, "y");
	console.log(dumpStr("grow", one));

	const bs: boolean[] = [true, false];
	bs.splice(0, 1, false);
	bs.splice(bs.length, 0, true);
	console.log("bool=" + bs[0].toString() + bs[1].toString() + bs[2].toString() + "len=" + bs.length.toString());

	const box: Box = { id: 9 };
	const bs2: Box[] = [{ id: 1 }, { id: 2 }];
	bs2.splice(0, 0, box);
	box.id = 42;
	let total: number = 0;
	for (const b of bs2) total = total + b.id;
	console.log("ref=" + bs2[0].id.toString() + " total=" + total.toString() + "len=" + bs2.length.toString());

	let churnOut = 0;
	for (let round = 0; round < 40; round += 1) {
		const churn: string[] = [];
		for (let i = 0; i < 12; i += 1) {
			churn.push("item" + i.toString() + "r" + round.toString());
		}
		churn.splice(3, 2, "new" + round.toString());
		churn.splice(0, 1, churn[churn.length - 1]);
		churnOut = churnOut + churn.length;
	}
	console.log("churn=" + churnOut.toString());

	const expect = "num=[9,0]len=2 str=[hello,hello]len=2 keep=hello/world grow=[y,x]len=2 "
		+ "bool=falsefalsetruelen=3 ref=42 total=45len=3 churn=440";
	const got = dumpNum("num", xs) + " " + dumpStr("str", ss) + " keep=" + head + "/" + tail
		+ " " + dumpStr("grow", one) + " bool=" + bs[0].toString() + bs[1].toString() + bs[2].toString()
		+ "len=" + bs.length.toString() + " ref=" + bs2[0].id.toString() + " total=" + total.toString()
		+ "len=" + bs2.length.toString() + " churn=" + churnOut.toString();
	console.log(got == expect ? "splice-insert all-ok" : "MISMATCH: " + got);
}

main();
