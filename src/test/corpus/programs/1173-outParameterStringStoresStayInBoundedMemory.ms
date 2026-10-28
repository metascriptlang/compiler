// @maxrss: 20
// @stdout: 1001 1001

function grow(out s: string, seed: string): void { s = seed + "!"; }
class Holder { name: string = ""; }

function main(): void {
	const seed = "x".repeat(1000);
	let local = "";
	const h = new Holder();
	for (let i = 0; i < 100000; i += 1) {
		grow(out local, seed);
		grow(out h.name, seed);
	}
	console.log(local.length.toString() + " " + h.name.length.toString());
}
main();
