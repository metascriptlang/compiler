// @xfail(raiser): the Raiser VM has no actors: Cannot resolve module 'std/actor'
// @stdout: counts 3 4 3

actor Sink {
	seen: int32 = 0;
	take(line: string): void {
		this.seen += line.length as int32;
	}
}

function run(args: string[], deliver: (line: string) => void): int32 {
	for (const a of args) deliver(a);
	return args.length;
}

function opts(): string[] {
	return ["-o", "x"];
}

function stream(target: string, deliver: (line: string) => void): int32 {
	return run([...opts(), target], deliver);
}

function pump(sink: Readonly<Sink>, target: string): int32 {
	return stream(target, (line: string): void => sink.take(line));
}

function build(base: Readonly<string[]>, tail: string): string[] {
	return [...base, tail];
}

function deeper(base: Readonly<string[]>, tail: string, deliver: (line: string) => void): int32 {
	return run(build(build(base, tail), "mid"), deliver);
}

function pumpDeeper(sink: Readonly<Sink>, base: Readonly<string[]>): int32 {
	return deeper(base, "host", (line: string): void => sink.take(line));
}

function viaParam(base: Readonly<string[]>, deliver: (line: string) => void): int32 {
	return run([...base], deliver);
}

function pumpParam(sink: Readonly<Sink>, base: Readonly<string[]>): int32 {
	return viaParam(base, (line: string): void => sink.take(line));
}

async function main(): Promise<void> {
	const sink = new Sink();
	const target = "host";
	const base = ["-o", "x"];
	const v = ["-v", "a", "b"];
	const n1 = await spawn(() => pump(sink, target));
	const n2 = await spawn(() => pumpDeeper(sink, base));
	const n3 = await spawn(() => pumpParam(sink, v));
	console.log("counts", n1, n2, n3);
}
await main();
