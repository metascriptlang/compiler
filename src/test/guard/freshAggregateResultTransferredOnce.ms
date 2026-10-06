let trace: string = "";

struct Resource { id: int32; name: string; }
struct Holder { resource: Resource; tag: string; }

function onDestroy(this x: Resource): void {
	trace += "destroy R " + x.id.toString() + "|";
}

function makeResource(id: int32): Resource { return { id, name: "resource" }; }

function nested(): void {
	const holder: Holder = { resource: makeResource(8), tag: "t" };
	trace += "end|";
}

nested();
trace += "done";
if (trace != "end|destroy R 8|done") {
	console.log("GUARD-FAIL nested " + trace);
	process.exit(1);
}

function elements(): void {
	const values: Resource[2] = [makeResource(3), makeResource(4)];
	trace += "elements|";
}

trace = "";
elements();
if (trace != "elements|destroy R 3|destroy R 4|") {
	console.log("GUARD-FAIL elements " + trace);
	process.exit(1);
}
console.log("GUARD-OK");
