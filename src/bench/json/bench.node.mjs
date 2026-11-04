// The typed rows have no node counterpart for a checked decode: node's decode row is JSON.parse plus a read of every
// field the MetaScript struct decode fills, and its encode row stringifies the parsed object.

import { bench } from "../harness.mjs";

let sink = 0;

function itemText(i) {
	const active = i % 3 == 0 ? "true" : "false";
	const score = (i * 37 % 200) / 2;
	return `{"id":${i},"name":"User ${i}","email":"user${i}@example.com",` +
		`"active":${active},"score":${score},"tags":["t${i % 7}","t${i % 11}","t${i % 13}"],` +
		`"address":{"street":"${i} Market Street","city":"City ${i % 50}","zip":"${10000 + i}"}}`;
}

function payloadText(count) {
	const parts = [];
	for (let i = 0; i < count; i++) parts.push(itemText(i));
	return `{"page":1,"total":${count},"items":[` + parts.join(",") + "]}";
}

function numbersText(count) {
	const parts = [];
	for (let i = 0; i < count; i++) {
		const whole = i * 7919 % 1000003 - 500000;
		parts.push(i % 2 == 0 ? `${whole}` : `${whole}.${i * 13 % 1000 + 1}`);
	}
	return "[" + parts.join(",") + "]";
}

function stringsText(count) {
	const parts = [];
	for (let i = 0; i < count; i++) {
		parts.push(`"line ${i} \\"quoted\\" C:\\\\path\\n\\ttab caf\\u00e9 \\u4e2d\\u6587 \\ud83d\\ude00 end"`);
	}
	return "[" + parts.join(",") + "]";
}

function checksum(text) {
	let hash = 0;
	for (let i = 0; i < text.length; i++) hash = (hash * 31 + text.charCodeAt(i)) % 1000000007;
	return `${text.length}:${hash}`;
}

function sizeOf(value) {
	return Array.isArray(value) ? value.length : Object.keys(value).length;
}

function decoded(text) {
	const payload = JSON.parse(text);
	let fields = payload.page + payload.total;
	for (const item of payload.items) {
		fields += item.id + item.name.length + item.email.length + (item.active ? 1 : 0) + item.score;
		for (const tag of item.tags) fields += tag.length;
		fields += item.address.street.length + item.address.city.length + item.address.zip.length;
	}
	sink += fields;
	return payload;
}

const small = itemText(4242);
const medium = payloadText(360);
const large = payloadText(5700);
const numbers = numbersText(7100);
const strings = stringsText(820);

const smallTree = JSON.parse(small);
const mediumTree = JSON.parse(medium);
const largeTree = JSON.parse(large);
const numbersTree = JSON.parse(numbers);
const stringsTree = JSON.parse(strings);
const mediumTyped = decoded(medium);

console.error(`check inputs ${small.length} ${medium.length} ${large.length} ${numbers.length} ${strings.length}`);
console.error(`check stringify ${checksum(JSON.stringify(smallTree))} ${checksum(JSON.stringify(mediumTree))} ` +
	`${checksum(JSON.stringify(largeTree))} ${checksum(JSON.stringify(numbersTree))} ${checksum(JSON.stringify(stringsTree))}`);
console.error(`check typed ${checksum(JSON.stringify(mediumTyped))}`);

bench("parse small object", 0, () => { sink += sizeOf(JSON.parse(small)); });
bench("parse medium 64 KB", medium.length, () => { sink += sizeOf(JSON.parse(medium)); });
bench("parse large 1 MB", large.length, () => { sink += sizeOf(JSON.parse(large)); });
bench("parse numbers 64 KB", numbers.length, () => { sink += sizeOf(JSON.parse(numbers)); });
bench("parse strings 64 KB", strings.length, () => { sink += sizeOf(JSON.parse(strings)); });
bench("stringify small object", 0, () => { sink += JSON.stringify(smallTree).length; });
bench("stringify medium 64 KB", medium.length, () => { sink += JSON.stringify(mediumTree).length; });
bench("stringify large 1 MB", large.length, () => { sink += JSON.stringify(largeTree).length; });
bench("stringify numbers 64 KB", numbers.length, () => { sink += JSON.stringify(numbersTree).length; });
bench("stringify strings 64 KB", strings.length, () => { sink += JSON.stringify(stringsTree).length; });
bench("decode typed medium 64 KB", medium.length, () => {
	const payload = decoded(medium);
	sink += payload.items.length + payload.items[payload.items.length - 1].id;
});
bench("encode typed medium 64 KB", medium.length, () => { sink += JSON.stringify(mediumTyped).length; });

if (sink < 0) console.log("unreachable", sink);
