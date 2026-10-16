// Checker — a Proxy<T, H> reads and writes only keys of T, with T's value types, and is not a T

import { strictErrorCount, hasError } from "./helpers";

const HEAD = "interface Todo { title: string; done: boolean; }\nclass Traps { get<K extends keyof Todo>(t: Todo, key: K): Todo[K] { return t[key]; } }\nconst todo: Todo = { title: \"a\", done: false };\nconst p = new Proxy(todo, new Traps());\n";

test "a Proxy member is a key of its target" {
	assert strictErrorCount(HEAD + "const s: string = p.title;\np.done = true;") == 0;
	assert hasError(HEAD + "p.owner;", "'owner' is not a key of 'Todo'");
	assert hasError(HEAD + "p.owner = 1;", "'owner' is not a key of 'Todo'");
}

test "a Proxy member has its target's value type" {
	assert hasError(HEAD + "const n: int32 = p.title;", "not assignable");
	assert hasError(HEAD + "p.done = \"yes\";", "not assignable");
}

test "a Proxy is not its target" {
	assert hasError(HEAD + "function show(t: Todo): void {}\nshow(p);", "got Proxy<Todo, Traps>, expected Todo");
	assert strictErrorCount(HEAD + "const t: Todo = proxyTarget(p);") == 0;
	assert hasError(HEAD + "console.log(p === todo);", "a Proxy<Todo, Traps> and a Todo are different types");
	assert strictErrorCount(HEAD + "console.log(proxyTarget(p) === todo);") == 0;
}

test "a Proxy is indexed by a key written in the source" {
	assert strictErrorCount(HEAD + "const s: string = p[\"title\"];\np[\"done\"] = true;") == 0;
	assert hasError(HEAD + "p[\"owner\"];", "'owner' is not a key of 'Todo'");
	assert hasError(HEAD + "let k: string = \"title\";\nk = \"done\";\nconsole.log(p[k]);", "a Proxy is indexed by a key written in the source");
}

test "an increment through a Proxy is a statement" {
	assert hasError("interface C { n: int32; }\nclass T { get<K extends keyof C>(t: C, key: K): C[K] { return t[key]; } }\nconst c: C = { n: 1 };\nconst p = new Proxy(c, new T());\nconst w = p.n++;", "'++' through a Proxy is a statement");
}

test "a handler trap of JavaScript's object model is refused by name" {
	const src = "interface Todo { title: string; }\nclass Bad { getPrototypeOf(target: Todo): Todo { return target; } construct(target: Todo): Todo { return target; } }\nconst p = new Proxy({ title: \"a\" } as Todo, new Bad());";
	assert hasError(src, "'Bad' declares the 'getPrototypeOf' trap");
	assert hasError(src, "'Bad' declares the 'construct' trap");
}

test "a Proxy does not cross an extern boundary" {
	const head = "interface Todo { title: string; }\nclass T { get<K extends keyof Todo>(target: Todo, key: K): Todo[K] { return target[key]; } }\n";
	assert hasError(head + "extern function show(n: int32, p: Proxy<Todo, T>): void;", "extern 'show' parameter 2: a Proxy crosses into foreign code");
	assert hasError(head + "extern function make(): Proxy<Todo, T>;", "extern 'make' return type: a Proxy crosses into foreign code");
	assert strictErrorCount(head + "extern function show(t: Todo): void;") == 0;
}
