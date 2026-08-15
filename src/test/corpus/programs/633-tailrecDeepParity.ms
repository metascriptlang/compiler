// @stdout: tailrec-parity r=
// Deep self-recursion must run in O(1) stack on BOTH targets: tailCallLower
// rewrites it to a loop before codegen (JS engines ship no proper tail calls).

function loop(n: int64, acc: int64): int64 {
	if (n <= 0) return acc;
	return loop(n - 1, acc + 1);
}

function grow(n: int64, s: string): string {
	if (n <= 0) return s;
	return grow(n - 1, s.slice(0, 1) + "y");
}

console.log("tailrec-parity r=" + loop(5000000, 0).toString() + "-" + grow(200000, "y").length.toString());
