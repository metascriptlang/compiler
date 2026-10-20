// @stdout: full {"mode":"~alt","need":"alt","lvl":3,"half":0.25,"exact":1.5,"tag":"close_window","on":true}
// @stdout: bare {"mode":null,"need":"~alt","lvl":null,"half":null,"exact":1.5,"tag":null,"on":null}
// @stdout: nested {"name":"haro","steps":[{"key":"a","dir":"up"},{"key":"b","dir":"down"}],"main":{"mode":"alt","need":"~alt","lvl":1,"half":0.5,"exact":1.5,"tag":null,"on":null}}
// @stdout: back {"mode":"~alt","need":"alt","lvl":3,"half":0.25,"exact":1.5,"tag":"close_window","on":true}
// @stdout: absent {"mode":null,"need":"alt","lvl":null,"half":null,"exact":1.5,"tag":null,"on":null}
// @stdout: nested back {"name":"haro","steps":[{"key":"a","dir":"up"},{"key":"b","dir":"down"}],"main":{"mode":"alt","need":"~alt","lvl":1,"half":0.5,"exact":1.5,"tag":null,"on":null}}
// @stdout: bad string err field 'need': expected "alt" | "~alt", got "Alt"
// @stdout: bad number err field 'lvl': expected 1 | 2 | 3, got 7
// @stdout: bad fraction err field 'exact': expected 1.5, got 2
// @stdout: bad kind err field 'need': expected "alt" | "~alt", got 5; field 'on': expected true, got false
// @stdout: missing err field 'need': expected "alt" | "~alt", got null
// @stdout: bad nested err field 'steps[1].dir': expected "down" | "up", got "left"; field 'main.mode': expected "alt" | "~alt", got "ALT"
// note: a field typed by literal types is stored as their base scalar, so it is written as that string, number or boolean and read back only when the value is one of the members; an absent optional field is written as null like `s?: string` (corpus `jsonNullableValues`).
type Mode = "alt" | "~alt";

interface Bind {
	mode?: Mode;
	need: Mode;
	lvl?: 1 | 2 | 3;
	half?: 0.5 | 0.25;
	exact: 1.5;
	tag?: "close_window";
	on?: true;
}

interface Step {
	key: string;
	dir: "up" | "down";
}

interface Keys {
	name: string;
	steps: Step[];
	main: Bind;
}

function showBind(label: string, r: Result<Bind, string>): void {
	if (r.ok) {
		console.log(label + " " + JSON.stringify(r.value));
	} else {
		console.log(label + " err " + r.error);
	}
}

function showKeys(label: string, r: Result<Keys, string>): void {
	if (r.ok) {
		console.log(label + " " + JSON.stringify(r.value));
	} else {
		console.log(label + " err " + r.error);
	}
}

const full: Bind = {
	mode: "~alt",
	need: "alt",
	lvl: 3,
	half: 0.25,
	exact: 1.5,
	tag: "close_window",
	on: true,
};
const bare: Bind = { need: "~alt", exact: 1.5 };
const keys: Keys = {
	name: "haro",
	steps: [{ key: "a", dir: "up" }, { key: "b", dir: "down" }],
	main: { mode: "alt", need: "~alt", lvl: 1, half: 0.5, exact: 1.5 },
};
console.log("full " + JSON.stringify(full));
console.log("bare " + JSON.stringify(bare));
console.log("nested " + JSON.stringify(keys));
showBind("back", JSON.parse<Bind>(JSON.stringify(full)));
showBind("absent", JSON.parse<Bind>('{"need":"alt","exact":1.5}'));
showKeys("nested back", JSON.parse<Keys>(JSON.stringify(keys)));
showBind("bad string", JSON.parse<Bind>('{"need":"Alt","exact":1.5}'));
showBind("bad number", JSON.parse<Bind>('{"need":"alt","lvl":7,"exact":1.5}'));
showBind("bad fraction", JSON.parse<Bind>('{"need":"alt","exact":2}'));
showBind("bad kind", JSON.parse<Bind>('{"need":5,"exact":1.5,"on":false}'));
showBind("missing", JSON.parse<Bind>('{"exact":1.5}'));
showKeys(
	"bad nested",
	JSON.parse<Keys>('{"name":"x","steps":[{"key":"a","dir":"up"},{"key":"b","dir":"left"}],'
		+ '"main":{"mode":"ALT","need":"alt","exact":1.5}}'),
);
