// @stdout: hooks true false true 2 qr ab

enum Kind { Text, Named, Scalar }
type Data = match (kind: Kind) {
	Kind.Text => { text: string },
	Kind.Named => { n: int32, name: string },
	Kind.Scalar => { value: float64 },
};
struct Payload { value: float64 | string; n: int32; }
struct Record { n: int32; text: string; }

function run(): void {
	const data: Data = { kind: Kind.Named, n: 1, name: "x" + "y" };
	let replaced: Data = data;
	replaced = { kind: Kind.Text, text: "a" + "b" };
	const payload: Payload = { value: "q" + "r", n: 1 };
	let changed: Payload = payload;
	changed = { value: 2.5, n: 2 };
	const first: Record = { n: 1, text: "m" + "n" };
	const second: Record = { n: 1, text: "m" + "n" };
	const left: [int32, string] = [1, "a"];
	const right: [int32, string] = [1, "b"];
	const original = payload.value as string;
	const text = replaced.kind == Kind.Text ? replaced.text : "missing";
	console.log(`hooks ${first == second} ${left == right} ${replaced.kind == Kind.Text} ${changed.n} ${original} ${text}`);
}
run();
