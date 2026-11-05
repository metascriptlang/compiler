// @stdout: top {"a":[1,2,{"b":null}],"c":"d"}
// @stdout: field {"name":"n","inner":"x"}
// @stdout: array {"name":"n","items":["x",2]}
// @stdout: map {"a":1,"b":"x"}
// @stdout: nullable {"meta":3} {"meta":null}
// note: JSON.stringify writes a JsonValue as the JSON it holds, at the top level and as a field, an array element, a Map value or a nullable field, as JSON.stringify of the parsed value does in node; before, it wrote the {"kind":…} record that carries it.
import { JsonValue } from "std/serialize/json/types";
import { jsonString, jsonInt } from "std/serialize/json/builder";
import { Map } from "std/core/struct";

struct Wrap {
	name: string;
	inner: JsonValue;
}
struct Many {
	name: string;
	items: JsonValue[];
}
struct Opt {
	meta: JsonValue | null;
}

const parsed = JSON.parseValue("{\"a\":[1,2,{\"b\":null}],\"c\":\"d\"}");
if (parsed.ok) console.log(`top ${JSON.stringify(parsed.value)}`);
const w: Wrap = { name: "n", inner: jsonString("x") };
console.log(`field ${JSON.stringify(w)}`);
const many: Many = { name: "n", items: [jsonString("x"), jsonInt(2)] };
console.log(`array ${JSON.stringify(many)}`);
const m = new Map<string, JsonValue>();
m.set("a", jsonInt(1));
m.set("b", jsonString("x"));
console.log(`map ${JSON.stringify(m)}`);
const o1: Opt = { meta: jsonInt(3) };
const o2: Opt = { meta: null };
console.log(`nullable ${JSON.stringify(o1)} ${JSON.stringify(o2)}`);
