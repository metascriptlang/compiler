import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

function caught(f) {
	try {
		f();
	} catch (e) {
		return e;
	}
	return null;
}

for (const kind of ["vec", "text"]) {
	const url = pathToFileURL(resolve(process.argv[2]));
	url.searchParams.set("result", kind);
	const m = await import(url.href);
	const failure = new RangeError("result conversion failed");
	const originalArray = globalThis.Array;
	const originalDecode = TextDecoder.prototype.decode;
	let thrown;
	try {
		if (kind === "vec") {
			globalThis.Array = new Proxy(originalArray, {
				construct(target, args) {
					if (args.length === 1 && args[0] === 3) throw failure;
					return Reflect.construct(target, args);
				},
			});
			thrown = caught(() => m.numbers());
		} else {
			TextDecoder.prototype.decode = function () { throw failure; };
			thrown = caught(() => m.text());
		}
	} finally {
		globalThis.Array = originalArray;
		TextDecoder.prototype.decode = originalDecode;
	}
	const blocked = caught(() => m.ping());
	console.log(`${kind} threw: ${thrown === failure}`);
	console.log(`${kind} blocked: ${
		blocked?.message.includes("the wasm half cannot run again") === true
	}`);
	console.log(`${kind} cause: ${blocked?.cause === failure}`);
}
