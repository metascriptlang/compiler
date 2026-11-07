export class TaExternalReads {
	paths: string[];
	seen: HashSet<string>;
}

export function createExternalReads(): TaExternalReads {
	return { paths: [], seen: new HashSet<string>() };
}

export function noteExternalRead(reads: TaExternalReads, path: string): boolean {
	if (reads.seen.has(path)) return false;
	reads.seen.add(path);
	reads.paths.push(path);
	return true;
}

test "a path read twice is noted once, in the order first read" {
	const reads = createExternalReads();
	assert noteExternalRead(reads, "/p/data.txt");
	assert noteExternalRead(reads, "/p/other.txt");
	assert !noteExternalRead(reads, "/p/data.txt");
	assert reads.paths.join(",") == "/p/data.txt,/p/other.txt";
}
