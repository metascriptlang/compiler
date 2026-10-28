// JavaScript Codegen — actor mailbox runtime

import { JSGenerator } from "./emit";

const RUNTIME = "function msActorRt() {\n"
	+ "  return globalThis.__msActorRt || (globalThis.__msActorRt = (() => {\n"
	+ "    const noproc = () => new globalThis.Error(\"noproc\");\n"
	+ "    const isThenable = (r) => r !== null && typeof r === \"object\" && typeof r.then === \"function\";\n"
	+ "    function live(a) {\n"
	+ "      const g = globalThis.__msActors;\n"
	+ "      return g !== void 0 && g.live.get(a.pid) === a;\n"
	+ "    }\n"
	+ "    function take(a) {\n"
	+ "      let q = a.__msq;\n"
	+ "      if (a.__msh >= 4096 && a.__msh * 2 >= q.length) { q = a.__msq = q.slice(a.__msh); a.__msh = 0; }\n"
	+ "      const m = q[a.__msh];\n"
	+ "      q[a.__msh++] = void 0;\n"
	+ "      return m;\n"
	+ "    }\n"
	+ "    function pump(a) {\n"
	+ "      while (a.__msh < a.__msq.length) {\n"
	+ "        const m = take(a);\n"
	+ "        if (!live(a)) { m.fail(); continue; }\n"
	+ "        let r;\n"
	+ "        const g = globalThis.__msActors, prev = g.cur, prevNext = g.curNext;\n"
	+ "        g.cur = a;\n"
	+ "        g.curNext = g.next;\n"
	+ "        try { r = m.run(); } catch (e) { globalThis.queueMicrotask(() => pump(a)); throw e; } finally { g.cur = prev; g.curNext = prevNext; }\n"
	+ "        if (isThenable(r)) {\n"
	+ "          r.then(() => pump(a), (e) => { pump(a); throw e; });\n"
	+ "          return;\n"
	+ "        }\n"
	+ "      }\n"
	+ "      a.__msq.length = 0;\n"
	+ "      a.__msh = 0;\n"
	+ "      a.__msBusy = false;\n"
	+ "    }\n"
	+ "    function post(a, run, fail) {\n"
	+ "      if (!live(a)) return false;\n"
	+ "      if (a.__msq === void 0) { a.__msq = []; a.__msh = 0; }\n"
	+ "      a.__msq.push({ run, fail });\n"
	+ "      if (!a.__msBusy) { a.__msBusy = true; globalThis.queueMicrotask(() => pump(a)); }\n"
	+ "      return true;\n"
	+ "    }\n"
	+ "    function send(a, f) { post(a, f, () => {}); }\n"
	+ "    function call(a, f) {\n"
	+ "      return new globalThis.Promise((res, rej) => {\n"
	+ "        const run = () => {\n"
	+ "          let r;\n"
	+ "          try { r = f(); } catch (e) { rej(e); return void 0; }\n"
	+ "          if (isThenable(r)) return r.then(res, rej);\n"
	+ "          res(r);\n"
	+ "          return void 0;\n"
	+ "        };\n"
	+ "        if (!post(a, run, () => rej(noproc()))) rej(noproc());\n"
	+ "      });\n"
	+ "    }\n"
	+ "    return { send, call };\n"
	+ "  })());\n"
	+ "}\n";

export const ACTOR_EXIT_STOP: string[] = [
	"var proc = globalThis.process;",
	"if (proc !== void 0 && typeof proc.on === \"function\") proc.on(\"beforeExit\", function () {",
	"\tvar g = globalThis.__msActors, stopped = 0, parked = [];",
	"\tfor (var e of g.live) {",
	"\t\tif (e[1].__msBusy) { parked.push(e[1]); continue; }",
	"\t\tg.live.delete(e[0]);",
	"\t\tstopped++;",
	"\t\tif (typeof e[1].onTerminate === \"function\") e[1].onTerminate(1);",
	"\t}",
	"\tif (stopped > 0) { globalThis.setImmediate(function () {}); return; }",
	"\tfor (var a of parked) {",
	"\t\tif (typeof a.onTerminate !== \"function\") continue;",
	"\t\tproc.stderr.write(\"Warning: Detected unsettled await in actor \" + a.constructor[globalThis.Symbol.for(\"metascript.typeDisplayName\")] + \" at exit: its onTerminate cannot run\\n\");",
	"\t\tproc.exitCode = 13;",
	"\t}",
	"});",
];

export function useActorRuntime(gen: JSGenerator): void {
	if (!gen.helpers.actorRuntime) {
		gen.helpers.actorRuntime = true;
		gen.staticSlots.push(RUNTIME);
	}
}
