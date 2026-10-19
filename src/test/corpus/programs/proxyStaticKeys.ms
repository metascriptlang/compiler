// @stdout: title=a done=true reads=2 writes=1 raw=true
// note: every member read and write of a Proxy<T, H> reaches the handler's trap typed by its key, and the target sees the write; same output on every lane (docs/LANG.md, Proxy).
interface Todo { title: string; done: boolean; }

let reads = 0;
let writes = 0;

class Traps {
	get<K extends keyof Todo>(target: Todo, key: K): Todo[K] {
		reads = reads + 1;
		return target[key];
	}
	set<K extends keyof Todo>(target: Todo, key: K, value: Todo[K]): boolean {
		writes = writes + 1;
		target[key] = value;
		return true;
	}
}

const todo: Todo = { title: "a", done: false };
const p = new Proxy(todo, new Traps());
p.done = true;
const t: string = p.title;
const d: boolean = p.done;
console.log("title=" + t + " done=" + String(d) + " reads=" + String(reads) + " writes=" + String(writes) + " raw=" + String(todo.done));
