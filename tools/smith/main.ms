import { argv, cwd } from "std/process";
import { Features, defaults, overlay, swarm } from "./features";
import { generate } from "./gen";
import { rerunBundle, runSeeds } from "./drive";
import { interesting, reduceInput } from "./reduce";

function usage(): int32 {
	console.log("usage: msc run tools/smith/main.ms gen <seed> [--features=\"key=value ...\"] [--plant=none|backend|opt] [--swarm]");
	console.log("       msc run tools/smith/main.ms run <firstSeed> <count> [--features=...] [--plant=...] [--swarm] [--san]");
	console.log("       msc run tools/smith/main.ms rerun <bundleDir>");
	console.log("       msc run tools/smith/main.ms reduce <bundleDir|program.ms> [--identity=<file>] [--jobs=4] [--cap=2700]");
	console.log("       msc run tools/smith/main.ms interesting <identityFile> <program.ms>");
	return 2;
}

function count(text: string, what: string): Result<int32, string> {
	if (text == "" || text.length > 15) { return Result.err(what + " '" + text + "' is not a number below 10^15"); }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return Result.err(what + " '" + text + "' is not a number"); }
	}
	return Result.ok(text.parseInt() as int32);
}

function seedOf(text: string): Result<uint64, string> {
	if (text == "" || text.length > 15) { return Result.err("seed '" + text + "' is not a number below 10^15"); }
	for (let i = 0; i < text.length; i++) {
		const code = text.charCodeAt(i);
		if (code < 48 || code > 57) { return Result.err("seed '" + text + "' is not a number"); }
	}
	return Result.ok(text.parseInt() as uint64);
}

function main(): int32 {
	const positional: string[] = [];
	let overlayText = "";
	let swarmed = false;
	let san = false;
	let identityPath = "";
	let jobs = 4;
	let cap = 2700;
	for (let i = 1; i < argv.length; i++) {
		const a = argv[i];
		if (a.startsWith("--features=")) {
			overlayText += " " + a.slice("--features=".length, a.length);
		} else if (a.startsWith("--plant=")) {
			overlayText += " plant=" + a.slice("--plant=".length, a.length);
		} else if (a.startsWith("--identity=")) {
			identityPath = a.slice("--identity=".length, a.length);
		} else if (a.startsWith("--jobs=") || a.startsWith("--cap=")) {
			const eq = a.indexOf("=");
			const n = count(a.slice(eq + 1, a.length), a.slice(0, eq));
			if (!n.ok || n.value < 1) {
				console.log("smith: " + a + " needs a positive number");
				return 2;
			}
			if (a.startsWith("--jobs=")) { jobs = n.value > 4 ? 4 : n.value; } else { cap = n.value; }
		} else if (a == "--swarm") {
			swarmed = true;
		} else if (a == "--san") {
			san = true;
		} else if (a.startsWith("--")) {
			console.log("smith: unknown flag " + a);
			return usage();
		} else {
			positional.push(a);
		}
	}
	const fr = Features.defaults().overlay(overlayText);
	if (!fr.ok) {
		console.log("smith: " + fr.error);
		return 2;
	}
	const f = fr.value;
	if (positional.length == 2 && positional[0] == "gen") {
		const seed = seedOf(positional[1]);
		if (!seed.ok) {
			console.log("smith: " + seed.error);
			return 2;
		}
		console.log(generate(seed.value, swarmed ? f.swarm(seed.value) : f));
		return 0;
	}
	if (positional.length == 3 && positional[0] == "run") {
		const first = seedOf(positional[1]);
		const n = count(positional[2], "count");
		if (!first.ok) {
			console.log("smith: " + first.error);
			return 2;
		}
		if (!n.ok || n.value < 1) {
			console.log("smith: count must be at least 1");
			return 2;
		}
		return runSeeds(first.value, n.value, f, swarmed, san);
	}
	if (positional.length == 2 && positional[0] == "rerun") {
		if (overlayText != "" || swarmed || san) {
			console.log("smith: rerun takes its features from the bundle; drop --features/--plant/--swarm/--san");
			return 2;
		}
		return rerunBundle(positional[1]);
	}
	if (positional.length == 2 && positional[0] == "reduce") { return reduceInput(cwd().replaceAll("\\", "/"), positional[1], identityPath, jobs, cap); }
	if (positional.length == 3 && positional[0] == "interesting") { return interesting(positional[1], positional[2]); }
	return usage();
}

process.exit(main());
