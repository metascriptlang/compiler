import { argv } from "std/process";
import { Features, defaults, overlay, swarm } from "./features";
import { generate } from "./gen";
import { rerunBundle, runSeeds } from "./drive";

function usage(): int32 {
	console.log("usage: msc run tools/smith/main.ms gen <seed> [--features=\"key=value ...\"] [--plant=none|backend|opt] [--swarm]");
	console.log("       msc run tools/smith/main.ms run <firstSeed> <count> [--features=...] [--plant=...] [--swarm]");
	console.log("       msc run tools/smith/main.ms rerun <bundleDir>");
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
	for (let i = 1; i < argv.length; i++) {
		const a = argv[i];
		if (a.startsWith("--features=")) {
			overlayText += " " + a.slice("--features=".length, a.length);
		} else if (a.startsWith("--plant=")) {
			overlayText += " plant=" + a.slice("--plant=".length, a.length);
		} else if (a == "--swarm") {
			swarmed = true;
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
		return runSeeds(first.value, n.value, f, swarmed);
	}
	if (positional.length == 2 && positional[0] == "rerun") {
		if (overlayText != "" || swarmed) {
			console.log("smith: rerun takes its features from the bundle; drop --features/--plant/--swarm");
			return 2;
		}
		return rerunBundle(positional[1]);
	}
	return usage();
}

process.exit(main());
