// @stdout: a 4 2 2 x 0.5 true 2
// @stdout: field 'limits.jobs': expected int, got string
// @stdout: field 'at.home.y': expected int, got string
// @stdout: 4 2
// @stdout: {"name":"b","limits":{"jobs":4,"cpus":1},"tags":{},"ratios":{"r":1.5},"flags":{"on":false},"at":{"home":{"x":3,"y":4}}}
// @stdout: 4 1 1.5 false 4
// JSON.parse decodes a JSON object into a Map<string, V> or Record<string, V> field and a top-level Record, strictly, and JSON.stringify writes one back as a JSON object, on every backend.
interface Point { x: int32; y: int32; }
interface Config { name: string; limits: Record<string, int32>; tags: Map<string, string>; ratios: Map<string, float64>; flags: Map<string, boolean>; at: Map<string, Point>; }

const parsed = JSON.parse<Config>('{"name":"a","limits":{"jobs":4,"cpus":2},"tags":{"t":"x"},"ratios":{"r":0.5},"flags":{"on":true},"at":{"home":{"x":1,"y":2}}}');
if (parsed.ok) {
	const c = parsed.value;
	console.log(c.name, c.limits.get("jobs"), c.limits.get("cpus"), c.limits.size, c.tags.get("t"), c.ratios.get("r"), c.flags.get("on"), c.at.get("home")!.y);
} else {
	console.log(parsed.error);
}
const wrongValue = JSON.parse<Config>('{"name":"a","limits":{"jobs":"four"},"tags":{},"ratios":{},"flags":{},"at":{}}');
console.log(wrongValue.ok ? "ok" : wrongValue.error);
const wrongNested = JSON.parse<Config>('{"name":"a","limits":{},"tags":{},"ratios":{},"flags":{},"at":{"home":{"x":1,"y":"two"}}}');
console.log(wrongNested.ok ? "ok" : wrongNested.error);
const top = JSON.parse<Record<string, int32>>('{"jobs":4,"cpus":2}');
console.log(top.ok ? `${top.value.get("jobs")} ${top.value.size}` : top.error);

const limits = new Map<string, int32>();
limits.set("jobs", 4);
limits.set("cpus", 1);
const ratios = new Map<string, float64>();
ratios.set("r", 1.5);
const flags = new Map<string, boolean>();
flags.set("on", false);
const at = new Map<string, Point>();
at.set("home", { x: 3, y: 4 });
const written: Config = { name: "b", limits, tags: new Map<string, string>(), ratios, flags, at };
const text = JSON.stringify(written);
console.log(text);
const back = JSON.parse<Config>(text);
console.log(back.ok ? `${back.value.limits.get("jobs")} ${back.value.limits.get("cpus")} ${back.value.ratios.get("r")} ${back.value.flags.get("on")} ${back.value.at.get("home")!.y}` : back.error);
