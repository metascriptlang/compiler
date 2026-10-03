// @xfail(raiser): != null yields 1 on raiser (NIM-REF CT-25, fixed on wt/nim-raiser 2adb86ea, not landed)
// @stdout: struct=false,true,false array=false,true,false,true
// note: a value that is never null, a struct or a fixed array `T[N]`, compared with `null` answers false for `==` and true for `!=`, on either side of the operator. Same output on every backend.

struct S { a: int32; }

function main(): void {
	const s: S = { a: 1 };
	const k: uint8[4] = [1, 2, 3, 4];
	console.log(`struct=${s == null},${s != null},${null == s} array=${k == null},${k != null},${null == k},${null != k}`);
}

main();
