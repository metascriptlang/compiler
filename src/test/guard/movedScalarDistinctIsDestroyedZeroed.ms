type Handle = distinct int32;
let observations: string = "";

function onDestroy(this handle: Handle): void {
	observations += (handle as int32).toString() + "|";
}

function open(id: int32): Handle { return id as Handle; }

function transfer(): void {
	let source = open(12);
	const taken = move source;
	if ((taken as int32) != 12) {
		console.log("GUARD-FAIL moved handle");
		process.exit(1);
	}
}

transfer();
if (observations != "12|0|") {
	console.log("GUARD-FAIL scalar " + observations);
	process.exit(1);
}
console.log("GUARD-OK");
