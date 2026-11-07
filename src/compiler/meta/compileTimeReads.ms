let _sink: (path: string) => void = (path: string): void => {};
let _installed = false;

export function installCompileTimeReadSink(sink: ((path: string) => void) | null): ((path: string) => void) | null {
	const outer = _installed ? _sink : null;
	_installed = sink != null;
	if (sink != null) _sink = sink;
	return outer;
}

export function recordCompileTimeRead(path: string): void {
	if (_installed) _sink(path);
}

test "a read reaches the installed sink, and restoring the outer one routes later reads back to it" {
	const outerSeen: string[] = [];
	const innerSeen: string[] = [];
	const entry = installCompileTimeReadSink((p: string): void => { outerSeen.push(p); });
	const outer = installCompileTimeReadSink((p: string): void => { innerSeen.push(p); });
	recordCompileTimeRead("/p/a.txt");
	installCompileTimeReadSink(outer);
	recordCompileTimeRead("/p/b.txt");
	installCompileTimeReadSink(entry);
	recordCompileTimeRead("/p/c.txt");
	assert innerSeen.join(",") == "/p/a.txt", innerSeen.join(",");
	assert outerSeen.join(",") == "/p/b.txt", outerSeen.join(",");
}
