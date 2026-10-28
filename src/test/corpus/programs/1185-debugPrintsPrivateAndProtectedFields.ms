// @stdout: {"secret":1,"name":"p"}
// @stdout: {"secret":1,"name":"p","tag":3,"extra":4}
// @stdout: {"secret":1,"name":"p"} {"inner":{"secret":1,"name":"p"},"n":2}
class P {
	private secret: int32 = 1;
	name: string = "p";
}
class Q extends P {
	protected tag: int32 = 3;
	extra: int32 = 4;
}
struct Holder {
	inner: P;
	n: int32;
}
function run(): void {
	console.log(`${new P()}`);
	console.log(`${new Q()}`);
	const xs: P[] = [new P()];
	console.log(`${xs}`, `${{ inner: new P(), n: 2 } as Holder}`);
}
run();
