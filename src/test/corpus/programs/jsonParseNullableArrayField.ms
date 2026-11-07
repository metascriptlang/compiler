// A struct field typed `T[] | null` decodes like a required `T[]` when present and to null when absent or null;
// another kind, or an element of the wrong kind, is a decode error. Struct elements and atomic elements alike,
// through JSON.parse<T> and the lenient jsonValueToStruct.
// @stdout: present 1 a | absent true | null true
// @stdout: object false | bad element false | number false
// @stdout: tags 2 x | tags absent true | tags bad false
// @stdout: lenient 1 b | lenient null true

import { jsonValueToStruct } from "std/serialize/json";

struct Rule {
	name: string;
}

struct Document {
	rules: Rule[] | null;
}

struct Tagged {
	id: int32;
	tags: string[] | null;
}

const present = JSON.parse<Document>('{"rules":[{"name":"a"}]}');
const absent = JSON.parse<Document>("{}");
const explicitNull = JSON.parse<Document>('{"rules":null}');
const firstName = present.ok && present.value.rules !== null ? present.value.rules[0].name : "-";
console.log(`present ${present.ok ? present.value.rules?.length ?? -1 : -2} ${firstName} | absent ${absent.ok && absent.value.rules === null} | null ${explicitNull.ok && explicitNull.value.rules === null}`);
console.log(`object ${JSON.parse<Document>('{"rules":{}}').ok} | bad element ${JSON.parse<Document>('{"rules":[{"name":1}]}').ok} | number ${JSON.parse<Document>('{"rules":3}').ok}`);

const tags = JSON.parse<Tagged>('{"id":1,"tags":["x","y"]}');
const noTags = JSON.parse<Tagged>('{"id":2}');
const firstTag = tags.ok && tags.value.tags !== null ? tags.value.tags[0] : "-";
console.log(`tags ${tags.ok ? tags.value.tags?.length ?? -1 : -2} ${firstTag} | tags absent ${noTags.ok && noTags.value.tags === null} | tags bad ${JSON.parse<Tagged>('{"id":3,"tags":"x"}').ok}`);

const lp = JSON.parseValue('{"rules":[{"name":"b"}]}');
const ln = JSON.parseValue('{"rules":null}');
if (lp.ok && ln.ok) {
	const lh: Document = jsonValueToStruct(lp.value, null as Document | null);
	const lnh: Document = jsonValueToStruct(ln.value, null as Document | null);
	console.log(`lenient ${lh.rules?.length ?? -1} ${lh.rules !== null ? lh.rules[0].name : "-"} | lenient null ${lnh.rules === null}`);
}
