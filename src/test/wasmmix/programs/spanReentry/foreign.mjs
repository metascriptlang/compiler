import { pathToFileURL } from "node:url";
import { resolve } from "node:path";

const m = await import(pathToFileURL(resolve(process.argv[2])).href);

function thrown(call) {
	try {
		call();
	} catch (e) {
		return `${e.name}: ${e.message}`;
	}
	return "no error";
}

let inner;
const w = m.lendWritable((xs) => {
	inner = thrown(() => m.twice(4));
	xs[0] = 10;
});
console.log(`writable: ${inner}`);
console.log(`writable result: ${w}`);

const r = m.lendReadonly((xs) => {
	inner = thrown(() => m.twice(1));
	return xs[0] + xs[1];
});
console.log(`readonly: ${inner}`);
console.log(`readonly result: ${r}`);

let nested;
let after;
const o = m.outer((n) => {
	m.lendWritable((xs) => {
		nested = thrown(() => m.twice(2));
	});
	after = m.twice(3);
	return after;
});
console.log(`nested lend: ${nested}`);
console.log(`after the lend: ${after}`);
console.log(`outer result: ${o}`);
console.log(`later call: ${m.twice(4)}`);
