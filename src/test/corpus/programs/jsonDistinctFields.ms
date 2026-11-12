// A field of a distinct type reads and writes as its base: a plain field, a nullable, an
// array element, a Vec element and a tagged struct's variant field round-trip through
// JSON.parse<T> and JSON.stringify, over an integer and over a string, and a value of the
// wrong kind is refused naming the field.
//
// @stdout: round {"host":7,"name":"a","maybe":null,"hosts":[1,2],"names":["x","y"]}
// @stdout: round {"host":8,"name":"b","maybe":9,"hosts":[],"names":[]}
// @stdout: round {"kind":"Dial","host":5,"name":"n","maybe":null}
// @stdout: round {"kind":"Dial","host":6,"name":"m","maybe":2}
// @stdout: round {"kind":"Hangup"}
// @stdout: vec 2 4
// @stdout: field 'host': expected int, got string
// @stdout: field 'name': expected string, got int
// @stdout: field 'maybe': expected int, got string
// @stdout: field 'hosts[1]': expected int, got string
// @stdout: field 'host': expected int, got string
// @stdout: lenient 7 a true 2
// @exit: 0

import { jsonValueToStruct } from "std/serialize/json";

type HostId = distinct int32;
type Name = distinct string;

struct Row {
	host: HostId;
	name: Name;
	maybe: HostId | null;
	hosts: HostId[];
	names: Name[];
}

struct Holder {
	ids: Vec<HostId>;
}

enum Kind {
	Dial,
	Hangup,
}

struct Cmd = match (kind: Kind) {
	Kind.Dial => { host: HostId, name: Name, maybe: HostId | null },
	Kind.Hangup => {},
};

function round<T>(text: string): void {
	const back = JSON.parse<T>(text);
	console.log(back.ok && JSON.stringify(back.value) == text ? "round " + text : "broken " + (back.ok ? JSON.stringify(back.value) : back.error));
}

function refused<T>(text: string): void {
	const back = JSON.parse<T>(text);
	console.log(back.ok ? "accepted" : back.error);
}

round<Row>('{"host":7,"name":"a","maybe":null,"hosts":[1,2],"names":["x","y"]}');
round<Row>('{"host":8,"name":"b","maybe":9,"hosts":[],"names":[]}');
round<Cmd>('{"kind":"Dial","host":5,"name":"n","maybe":null}');
round<Cmd>('{"kind":"Dial","host":6,"name":"m","maybe":2}');
round<Cmd>('{"kind":"Hangup"}');
const holder = JSON.parse<Holder>('{"ids":[2,4]}');
console.log(holder.ok ? "vec " + holder.value.ids.length + " " + (holder.value.ids[1] as int32) : holder.error);
refused<Row>('{"host":"x","name":"a","maybe":null,"hosts":[],"names":[]}');
refused<Row>('{"host":1,"name":3,"maybe":null,"hosts":[],"names":[]}');
refused<Row>('{"host":1,"name":"a","maybe":"p","hosts":[],"names":[]}');
refused<Row>('{"host":1,"name":"a","maybe":null,"hosts":[1,"z"],"names":[]}');
refused<Cmd>('{"kind":"Dial","host":"x","name":"n","maybe":null}');
const lenient = JSON.parseValue('{"host":7,"name":"a","maybe":null,"hosts":[1,2],"names":[]}');
if (lenient.ok) {
	const r: Row = jsonValueToStruct(lenient.value, null as Row | null);
	console.log("lenient " + (r.host as int32) + " " + (r.name as string) + " " + (r.maybe == null) + " " + r.hosts.length);
}
