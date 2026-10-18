// @xfail(raiser): error: Cannot resolve module 'std/core/buffer'
// @stdout: cbor-self-ref ok b c 3
import { cborEncode, decode, cborValueToStruct, cborInt, _cborArrayOfStructs, _cborToStructArray } from "std/serialize/cbor";

struct Node {
	key: string;
	children: Node[];
}

struct Group {
	label: string;
	members: Member[];
}

struct Member {
	id: int32;
	groups: Group[];
}

const root: Node = { key: "a", children: [{ key: "b", children: [{ key: "c", children: [] }] }] };
const wire = decode(cborEncode(root));
const back: Node = cborValueToStruct(wire.ok ? wire.value : cborInt(0), null as Node | null);

const group: Group = { label: "x", members: [{ id: 3, groups: [{ label: "z", members: [] }] }] };
const groupWire = decode(cborEncode(group));
const group2: Group = cborValueToStruct(groupWire.ok ? groupWire.value : cborInt(0), null as Group | null);

const ok = back.children.length == 1 && group2.members[0].groups[0].label == "z";
console.log((ok ? "cbor-self-ref ok " : "cbor-self-ref bad ") + back.children[0].key + " " + back.children[0].children[0].key + " " + group2.members[0].id.toString());
