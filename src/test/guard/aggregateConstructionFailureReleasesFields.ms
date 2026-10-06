struct Resource { id: int32; name: string; }
struct Holder { resource: Resource; tag: string; }
struct Nested { holder: Holder; tag: string; }
let released: string = "";

function expect(expected: string): void {
	if (released != expected) {
		console.log("GUARD-FAIL interrupted construction " + released);
		process.exit(1);
	}
}

function onDestroy(this x: Resource): void {
	if (x.id != 0) released += x.id.toString() + "|";
}

function makeResource(id: int32): Resource { return { id, name: "resource" }; }
function fail(): string { throw new Error("later field"); }
function failResource(): Resource { throw new Error("later element"); }

function interruptedField(): void {
	const holder: Holder = { resource: makeResource(8), tag: fail() };
	process.exit(1);
}

function interruptedNested(): void {
	const nested: Nested = { holder: { resource: makeResource(9), tag: "t" }, tag: fail() };
	process.exit(1);
}

function interruptedArray(): void {
	const values: Resource[2] = [makeResource(10), failResource()];
	process.exit(1);
}

let caught: int32 = 0;
try { interruptedField(); } catch (e) { caught += 1; }
expect("8|");
try { interruptedNested(); } catch (e) { caught += 1; }
expect("8|9|");
try { interruptedArray(); } catch (e) { caught += 1; }
expect("8|9|10|");
if (caught != 3) {
	console.log("GUARD-FAIL caught " + caught.toString());
	process.exit(1);
}
console.log("GUARD-OK");
