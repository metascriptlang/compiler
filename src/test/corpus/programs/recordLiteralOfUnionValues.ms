// @stdout: Home home | Profile user/:id | Tab t | Deep d | Home home | Count 3 | h 1 | k two
interface Cfg { path?: string; exact?: boolean; screens?: Record<string, string | Cfg> }
const config: Record<string, string | Cfg> = { Home: "home", Profile: { path: "user/:id", screens: { Tab: "t", Deep: { path: "d" } } } };
const out: string[] = [];
for (const [k, v] of config) {
	if (typeof v === "string") { out.push(k + " " + v); } else {
		out.push(k + " " + (v.path ?? "-"));
		if (v.screens != null) {
			for (const [sk, sv] of v.screens) out.push(sk + " " + (typeof sv === "string" ? sv : sv.path ?? "-"));
		}
	}
}
const mixed: Record<string, string | int32> = { Home: "home", Count: 3 };
for (const [k, v] of mixed) out.push(k + " " + String(v));
const hashed: HashMap<string, int32 | string> = { h: 1 };
const keyed: Map<string, int32 | string> = { k: "two" };
for (const [k, v] of hashed) out.push(k + " " + String(v));
for (const [k, v] of keyed) out.push(k + " " + String(v));
console.log(out.join(" | "));
