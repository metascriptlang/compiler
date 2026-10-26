// @stdout: 2788 true false true true
// Strings through every VM string operation on text that is not one byte per character: the same output on C and on the Raiser VM.

function build(n: int32): string {
	let acc = "";
	for (let i = 0; i < n; i += 1) acc += `é${i}€`;
	return acc;
}

function main(): void {
	const wide = "aé€😀z";
	console.log(`${wide.length} ${wide.slice(1, 3)} ${wide.charCodeAt(3)}`);
	const grown = build(300);
	console.log(`${grown.length} ${grown.slice(0, 8)} ${grown.slice(-6)} ${grown.charCodeAt(5)}`);
	const joined = grown + "|" + wide + "|" + grown;
	console.log(`${joined.length} ${joined === grown + "|" + wide + "|" + grown} ${joined < grown} ${grown <= grown} ${"b" > "a"}`);
	let self = "ab";
	for (let i = 0; i < 6; i += 1) self = self + self;
	const parts: string[] = [];
	for (let i = 0; i < 40; i += 1) parts.push(`k${i}` + (i % 2 == 0 ? "é" : "e"));
	const box = { name: parts[7], tail: parts[38] + "!" };
	console.log(`${self.length} ${parts.join(",").length} ${box.name} ${box.tail} ${"".length} ${("" + "").length}`);
	console.log(`${wide.slice(2).length} ${wide.slice(-1)} ${parts[3].length}`);
}

main();
