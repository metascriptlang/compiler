// Run one binary at a time: a parallel job moves every number.
// Every input is ASCII, so a string's length is its byte count.

import { bench } from "../harness";

struct Address { street: string; city: string; zip: string; }
struct Item {
	id: int32;
	name: string;
	email: string;
	active: boolean;
	score: number;
	tags: string[];
	address: Address;
}
struct Payload { page: int32; total: int32; items: Item[]; }

let sink: number = 0;

function itemText(i: int32): string {
	const active = i % 3 == 0 ? "true" : "false";
	const doubledScore: number = i * 37 % 200;
	const score = doubledScore / 2;
	return `{"id":${i},"name":"User ${i}","email":"user${i}@example.com",` +
		`"active":${active},"score":${score},"tags":["t${i % 7}","t${i % 11}","t${i % 13}"],` +
		`"address":{"street":"${i} Market Street","city":"City ${i % 50}","zip":"${10000 + i}"}}`;
}

function payloadText(count: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < count; i++) parts.push(itemText(i));
	return `{"page":1,"total":${count},"items":[` + parts.join(",") + "]}";
}

function numbersText(count: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < count; i++) {
		const whole = i * 7919 % 1000003 - 500000;
		parts.push(i % 2 == 0 ? `${whole}` : `${whole}.${i * 13 % 1000 + 1}`);
	}
	return "[" + parts.join(",") + "]";
}

function stringsText(count: int32): string {
	const parts: string[] = [];
	for (let i = 0; i < count; i++) {
		parts.push(`"line ${i} \\"quoted\\" C:\\\\path\\n\\ttab caf\\u00e9 \\u4e2d\\u6587 \\ud83d\\ude00 end"`);
	}
	return "[" + parts.join(",") + "]";
}

function checksum(text: string): string {
	let hash: number = 0;
	for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 1000000007;
	return `${text.length}:${hash}`;
}

function parsed(text: string): JsonValue {
	const result = JSON.parseValue(text);
	if (!result.ok) throw new Error("parse failed: " + result.error);
	return result.value;
}

function decoded(text: string): Payload {
	const result = JSON.parse<Payload>(text);
	if (!result.ok) throw new Error("decode failed: " + result.error);
	return result.value;
}

const small = itemText(4242);
const medium = payloadText(360);
const large = payloadText(5700);
const numbers = numbersText(7100);
const strings = stringsText(820);

const smallTree = parsed(small);
const mediumTree = parsed(medium);
const largeTree = parsed(large);
const numbersTree = parsed(numbers);
const stringsTree = parsed(strings);
const mediumTyped = decoded(medium);

console.error(`check inputs ${small.length} ${medium.length} ${large.length} ${numbers.length} ${strings.length}`);
console.error(`check stringify ${checksum(stringify(smallTree))} ${checksum(stringify(mediumTree))} ` +
	`${checksum(stringify(largeTree))} ${checksum(stringify(numbersTree))} ${checksum(stringify(stringsTree))}`);
console.error(`check typed ${checksum(JSON.stringify(mediumTyped))}`);

bench("parse small object", 0, () => { sink += parsed(small).length(); });
bench("parse medium 64 KB", medium.length, () => { sink += parsed(medium).length(); });
bench("parse large 1 MB", large.length, () => { sink += parsed(large).length(); });
bench("parse numbers 64 KB", numbers.length, () => { sink += parsed(numbers).length(); });
bench("parse strings 64 KB", strings.length, () => { sink += parsed(strings).length(); });
bench("stringify small object", 0, () => { sink += stringify(smallTree).length; });
bench("stringify medium 64 KB", medium.length, () => { sink += stringify(mediumTree).length; });
bench("stringify large 1 MB", large.length, () => { sink += stringify(largeTree).length; });
bench("stringify numbers 64 KB", numbers.length, () => { sink += stringify(numbersTree).length; });
bench("stringify strings 64 KB", strings.length, () => { sink += stringify(stringsTree).length; });
bench("decode typed medium 64 KB", medium.length, () => {
	const payload = decoded(medium);
	sink += payload.items.length + payload.items[payload.items.length - 1].id;
});
bench("encode typed medium 64 KB", medium.length, () => { sink += JSON.stringify(mediumTyped).length; });

if (sink < 0) console.log("unreachable", sink);
