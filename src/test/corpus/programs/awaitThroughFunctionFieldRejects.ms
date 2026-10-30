// @stdout: field caught refused camera
// @stdout: local caught refused a
// @stdout: class caught refused b
interface Reply { status: string; }
interface Services { ask: (name: string) => Promise<Reply>; }

async function failing(name: string): Promise<Reply> {
	if (name !== "") { throw new Error("refused " + name); }
	return { status: "ok" };
}

const services: Services = { ask: failing };
class Svc { ask: (name: string) => Promise<Reply> = failing; }

async function viaField(): Promise<string> { const reply = await services.ask("camera"); return reply.status; }
async function viaLocal(): Promise<string> { const ask = failing; const r = await ask("a"); return r.status; }
async function viaClass(): Promise<string> { const s = new Svc(); const r = await s.ask("b"); return r.status; }

async function tryIt(name: string, f: () => Promise<string>): Promise<void> {
	try { console.log(name + " resolved " + await f()); } catch (e) { console.log(name + " caught " + (e as Error).message); }
}
async function main(): Promise<void> {
	await tryIt("field", viaField);
	await tryIt("local", viaLocal);
	await tryIt("class", viaClass);
}
main();
