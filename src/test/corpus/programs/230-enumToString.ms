enum Color { Red, Green, Blue }

function shout(c: Color): string {
	return Color[c] + "=" + c.toString();
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
}
main();
