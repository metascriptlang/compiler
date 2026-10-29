// @stdout: 7 7

struct Base { name: string; code: int32; }
struct Derived extends Base { extra: number[]; }

function main(): void {
	const d: Derived = { name: "n" + "1", code: 7, extra: [1, 2, 3] };
	const b: Base = d;
	const e: Derived = { name: "n" + "2", code: 7, extra: [4, 5] };
	const holder: Base[] = [];
	holder.push(e);
	console.log(b.code, holder[0].code);
}
main();
