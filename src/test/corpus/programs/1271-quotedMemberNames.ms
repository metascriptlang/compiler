// @stdout: {"data-id":"a","aria-label":"b"} a b
// @stdout: x 1 x
// @stdout: {"data-probe":"p"} p
// @stdout: 1 {"http-equiv":"h","n":3}
interface Props {
	"data-id": string;
	"aria-label"?: string;
}
const p: Props = { "data-id": "a", "aria-label": "b" };
console.log(JSON.stringify(p), p["data-id"], p["aria-label"]);

type Pair = { "x-y": string; n: int32 };
const pair: Pair = { "x-y": "x", n: 1 };
const { "x-y": renamed } = pair;
console.log(pair["x-y"], pair.n, renamed);

class Box {
	"data-probe": string = "p";
}
const box = new Box();
console.log(JSON.stringify(box), box["data-probe"]);

struct Key {
	"http-equiv": string;
	n: int32;
}
const keys = new Set<Key>();
keys.add({ "http-equiv": "h", n: 3 });
keys.add({ "http-equiv": "h", n: 3 });
let first = "";
for (const k of keys) first = JSON.stringify(k);
console.log(keys.size, first);
