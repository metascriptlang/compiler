// @stdout: codes Bad Neg Ok | shades Hi Lo
// @xfail(raiser): raiser runtime error: cannot evaluate 'Color' at comptime: symbol kind is Enum
enum Color { Red, Green, Blue }
enum Code { Ok = 5, Bad = 9, Neg = -1 }
enum Shade { Lo, Hi }

function shout(c: Color): string {
	return Color[c] + "=" + c.toString();
}

function codes(): string {
	const c: Code = Code.Bad;
	const n: int32 = 5;
	return "codes " + String(c) + " " + Code.Neg.toString() + " " + Code[n];
}

function shade(k: int32): Shade {
	return k as Shade;
}

function shades(): string {
	const k: int32 = 1;
	return "shades " + Shade[k] + " " + shade(0).toString();
}

function main(): void {
	console.log(shout(Color.Red));
	console.log(shout(Color.Green));
	console.log(shout(Color.Blue));
	for (let i: int32 = 0; i < 3; i += 1) {
		console.log(Color[i]);
	}
	const oob: int32 = 7;
	console.log(Color[oob]);
	console.log(codes() + " | " + shades());
}
main();
