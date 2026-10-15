function check(n: int32): void {
	if (n > 0) throw new Error("m failed");
}
function make(s: string): string {
	return "m " + s;
}
check(1);
export const label = make("ready");
