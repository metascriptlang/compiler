// @stdout: b 30 c calls=2 g:n s:n g:n s:n s:title g:title g:n s:n s:title G:n
// note: a compound write through a Proxy<T, H> is a read through get then a write through set, a receiver with effects runs once, and a handler without set writes the target; same output on every lane (docs/LANG.md, Proxy).
interface Todo { title: string; n: int32; }
let log = "";
class Traps {
	get<K extends keyof Todo>(target: Todo, key: K): Todo[K] { log = log + "g:" + key + " "; return target[key]; }
	set<K extends keyof Todo>(target: Todo, key: K, value: Todo[K]): boolean { log = log + "s:" + key + " "; target[key] = value; return true; }
}
class GetOnly { get<K extends keyof Todo>(target: Todo, key: K): Todo[K] { log = log + "G:" + key + " "; return target[key]; } }
const todo: Todo = { title: "a", n: 1 };
const p = new Proxy(todo, new Traps());
p.n += 2;
p.n++;
p["title"] = "b";
const t: string = p["title"];
let calls = 0;
function getP(): Proxy<Todo, Traps> { calls = calls + 1; return p; }
getP().n -= 1;
getP().title = "c";
const q = new Proxy(todo, new GetOnly());
q.n *= 10;
console.log(t + " " + String(todo.n) + " " + todo.title + " calls=" + String(calls) + " " + log);
