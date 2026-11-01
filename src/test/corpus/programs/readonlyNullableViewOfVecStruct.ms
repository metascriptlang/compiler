// @stdout: false 1 | b 2 | -
struct Curve { times: Vec<float32>; }
interface Info { name: string; tags: string[]; }
const x: Readonly<Curve> | null = { times: [1.0] };
function find(all: Readonly<Info[]>, name: string): Readonly<Info> | null {
	for (const i of all) { if (i.name == name) return i; }
	return null;
}
const infos: Info[] = [{ name: "a", tags: ["t"] }, { name: "b", tags: ["u", "v"] }];
const got = find(infos, "b");
const none = find(infos, "z");
console.log(x == null, x == null ? 0 : x.times.length, "|", got == null ? "-" : got.name + " " + String(got.tags.length), "|", none == null ? "-" : none.name);
