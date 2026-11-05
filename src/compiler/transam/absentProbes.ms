export class TaAbsentProbes {
	depth: int32;
	revision: int32;
	paths: HashSet<string>;
	diskProbes: int32;
}

export function createAbsentProbes(): TaAbsentProbes {
	return {
		depth: 0,
		revision: -1,
		paths: new HashSet<string>(),
		diskProbes: 0,
	};
}

export function enterCheckProbes(probes: TaAbsentProbes): void {
	probes.depth += 1;
}

export function leaveCheckProbes(probes: TaAbsentProbes): void {
	if (probes.depth <= 0) {
		throw new Error("internal: leaveCheckProbes without a check in progress");
	}
	probes.depth -= 1;
	if (probes.depth == 0) {
		probes.paths = new HashSet<string>();
	}
}

function inCheckAt(
	probes: TaAbsentProbes,
	revision: int32,
): HashSet<string> | null {
	if (probes.depth == 0) {
		return null;
	}
	if (probes.revision != revision) {
		probes.revision = revision;
		probes.paths = new HashSet<string>();
	}
	return probes.paths;
}

export function knownAbsentAt(
	probes: TaAbsentProbes,
	path: string,
	revision: int32,
): boolean {
	const paths = inCheckAt(probes, revision);
	return paths != null && paths.has(path);
}

export function recordAbsentAt(
	probes: TaAbsentProbes,
	path: string,
	revision: int32,
): void {
	const paths = inCheckAt(probes, revision);
	if (paths != null) {
		paths.add(path);
	}
}

export function recordDiskProbe(probes: TaAbsentProbes): void {
	probes.diskProbes += 1;
}

test "an absent path is known only inside the check and at the revision it was probed at" {
	const probes = createAbsentProbes();
	recordAbsentAt(probes, "/a.ms", 3);
	assert !knownAbsentAt(probes, "/a.ms", 3);
	enterCheckProbes(probes);
	recordAbsentAt(probes, "/a.ms", 3);
	assert knownAbsentAt(probes, "/a.ms", 3);
	assert !knownAbsentAt(probes, "/b.ms", 3);
	enterCheckProbes(probes);
	assert knownAbsentAt(probes, "/a.ms", 3);
	leaveCheckProbes(probes);
	assert knownAbsentAt(probes, "/a.ms", 3);
	assert !knownAbsentAt(probes, "/a.ms", 4);
	recordAbsentAt(probes, "/a.ms", 4);
	leaveCheckProbes(probes);
	assert !knownAbsentAt(probes, "/a.ms", 4);
	enterCheckProbes(probes);
	assert !knownAbsentAt(probes, "/a.ms", 4);
	leaveCheckProbes(probes);
}

test "leaving a check that was never entered is an internal error" {
	let message = "";
	try {
		leaveCheckProbes(createAbsentProbes());
	} catch (e) {
		message = (e as Error).message;
	}
	assert message.contains("without a check in progress"), message;
}
