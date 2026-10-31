// A string copied into a buffer that already holds a checked ASCII string must report the
// length and code units of the copied bytes, in both directions between ASCII and non-ASCII,
// and a concat, trim or array copy answers the same as a string built from scratch.

function id(s: string): string { return s; }

function grow(first: int32, count: int32): string {
	let s = "";
	for (let j: int32 = 0; j < count; j++) s += String.fromCharCode(first + (j % 26));
	return s;
}

function report(tag: string, s: string): void {
	console.log(tag + " len=" + s.length + " c0=" + s.charCodeAt(0) + " c2=" + s.charCodeAt(2) + " last=" + s.charCodeAt(s.length - 1));
}

function main(): void {
	const ascii = grow(97, 8);
	const wide = grow(0x430, 4);
	const mixed = ascii + wide;

	let slot = grow(97, 20);
	report("slot0", slot);
	slot = ascii;
	report("slot1", slot);
	slot = wide;
	report("slot2", slot);
	slot = ascii;
	report("slot3", slot);

	let wideSlot = grow(0x430, 10);
	report("wideSlot0", wideSlot);
	wideSlot = ascii;
	report("wideSlot1", wideSlot);
	wideSlot = mixed;
	report("wideSlot2", wideSlot);

	const parts: string[] = [grow(97, 20), grow(97, 20)];
	report("part0", parts[0]);
	report("part1", parts[1]);
	parts[0] = wide;
	parts[1] = mixed;
	report("part0", parts[0]);
	report("part1", parts[1]);
	parts[0] = ascii;
	report("part0", parts[0]);

	report("cat0", id(ascii) + id(ascii));
	report("cat1", id(ascii) + id(wide));
	report("cat2", id(wide) + id(ascii));
	report("cat3", id("") + id(wide));
	report("cat4", id(ascii) + id(""));
	report("cat5", ascii + "-" + wide + "-" + ascii);

	report("trim0", ("  " + ascii + "  ").trim());
	report("trim1", ("  " + wide + "  ").trim());
	report("trim2", ("  " + mixed + "  ").trim());

	const copies = parts.slice(0, 2);
	report("copy0", copies[0]);
	const again = [...parts, mixed];
	report("again2", again[2]);
}

main();
