import { compileProjectToCWithStd, compileToCWithStd, MapEntry } from "../helpers";

const TODO = "interface Todo { title: string; done: boolean; }\nconst todo: Todo = { title: \"a\", done: false };\n";
const PASS = "class Pass { get<K extends keyof Todo>(target: Todo, key: K): Todo[K] { return target[key]; } }\nconst p = new Proxy(todo, new Pass());\n";

function cOf(body: string): string {
	const c = compileToCWithStd(TODO + body);
	return c.ok ? c.value : "error: " + c.error;
}

// The body of each routine defined with a C name that starts with `prefix`, one per instance.
function bodiesOf(c: string, prefix: string): string[] {
	const bodies: string[] = [];
	for (const line of c.split("\n")) {
		if (!line.includes(" " + prefix) || !line.endsWith(") {")) continue;
		const at = c.indexOf(line) + line.length;
		bodies.push(c.slice(at, c.indexOf("\n}\n", at)));
	}
	return bodies;
}

test "proxyStaticKey: a pass-through get on a key written in the source is the field read" {
	const c = cOf(PASS + "console.log(p.title, p.done);\n");
	const bodies = bodiesOf(c, "Pass_get");
	assert bodies.length == 2, c.slice(0, 400);
	assert bodies[0].includes("(*target).title") || bodies[1].includes("(*target).title"), bodies.join("\n---\n");
	assert bodies[0].includes("(*target).done") || bodies[1].includes("(*target).done"), bodies.join("\n---\n");
	for (const b of bodies) assert !b.includes("msStringEquals") && !b.includes("msStringCompare"), b;
}

const STORE = "let reads = 0;\nclass Hidden<T> { get<K extends keyof T>(t: T, key: K): T[K] { reads = reads + 1; return t[key]; } }\nexport class Shown<T> { get<K extends keyof T>(t: T, key: K): T[K] { reads = reads + 1; return t[key]; } }\nexport function hidden<T>(t: T): Proxy<T, Hidden<T>> { return new Proxy(t, new Hidden<T>()); }\nexport function shown<T>(t: T): Proxy<T, Shown<T>> { return new Proxy(t, new Shown<T>()); }\n";

function appC(make: string): string {
	const entries: MapEntry[] = [
		{ entryPath: "test/proxyStaticKey/store.ms", entrySource: STORE },
		{ entryPath: "test/proxyStaticKey/app.ms", entrySource: `import { ${make} } from "./store";\ninterface Todo { title: string; }\nconst s = ${make}<Todo>({ title: "a" });\nconsole.log(s.title);\n` },
	];
	return compileProjectToCWithStd(entries, "test/proxyStaticKey/app.ms");
}

test "proxyStaticKey: a handler's trap is called where the proxy is read, or the read is refused" {
	const shown = appC("shown");
	assert !shown.startsWith("ERROR") && bodiesOf(shown, "Shown_get").length == 1, shown.slice(0, 400);
	assert appC("hidden").includes("the 'get' trap of 'Hidden<Todo>' cannot be called here: export 'Hidden' from its module"), appC("hidden").slice(0, 400);
}
