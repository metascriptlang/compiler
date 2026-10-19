import { argv, cwd } from "std/process";
import { ensureDir, exists, readDir, writeFile } from "std/fs";
import { Features, Plant, defaults, overlay, swarm } from "./features";
import { generate } from "./gen";
import { generateProject } from "./proj";
import { rerunBundle, runSeeds } from "./drive";
import { interesting, reduceInput } from "./reduce";
import { coverSeeds } from "./cov";
import { caseFor, runDiag, runPlanted } from "./diag";

function usage(): int32 {
	console.log("usage: msc run tools/smith/main.ms gen <seed> [--features=\"key=value ...\"] [--plant=none|backend|opt|san|model|meta] [--swarm] [--out=<new or empty dir>]");
	console.log("       (modules=N in --features splits the program into main.ms and m0.ms..; it needs --out)");
	console.log("       msc run tools/smith/main.ms run <firstSeed> <count> [--features=...] [--plant=...] [--swarm] [--san]");
	console.log("       msc run tools/smith/main.ms cov <firstSeed> <count> --msc=<instrumented msc> [--features=...] [--swarm]");
	console.log("       msc run tools/smith/main.ms rerun <bundleDir>");
	console.log("       msc run tools/smith/main.ms reduce <bundleDir|program.ms> [--identity=<file>] [--jobs=4] [--cap=2700]");
	console.log("       msc run tools/smith/main.ms interesting <identityFile> <program.ms>");
	console.log("       msc run tools/smith/main.ms diag <firstSeed> <count> [--plant]");
	console.log("       msc run tools/smith/main.ms diag show <seed>");
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
	let diagPlant = false;
	let san = false;
	let identityPath = "";
	let covMsc = "";
	let outDir = "";
	let jobs = 4;
	let cap = 2700;
	for (let i = 1; i < argv.length; i++) {
		const a = argv[i];
		if (a.startsWith("--features=")) {
			overlayText += " " + a.slice("--features=".length, a.length);
		} else if (a.startsWith("--plant=")) {
			overlayText += " plant=" + a.slice("--plant=".length, a.length);
		} else if (a.startsWith("--msc=")) {
			covMsc = a.slice("--msc=".length, a.length);
		} else if (a.startsWith("--out=")) {
			outDir = a.slice("--out=".length, a.length);
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
		} else if (a == "--plant") {
			diagPlant = true;
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
	if (diagPlant && (positional.length == 0 || positional[0] != "diag")) {
		console.log("smith: --plant without a value belongs to diag; the generator takes --plant=<kind>");
		return 2;
	}
	if (positional.length == 2 && positional[0] == "gen") {
		const seed = seedOf(positional[1]);
		if (!seed.ok) {
			console.log("smith: " + seed.error);
			return 2;
		}
		const g = swarmed ? f.swarm(seed.value) : f;
		if (g.modules == 0 && outDir == "") {
			console.log(generate(seed.value, g));
			return 0;
		}
		if (g.modules == 0 || outDir == "") {
			console.log("smith: --out and modules=N go together: a project is several files and needs a directory");
			return 2;
		}
		if (exists(outDir) && readDir(outDir).length > 0) {
			console.log("smith: " + outDir + " is not empty");
			return 2;
		}
		const made = generateProject(seed.value, g);
		if (!made.ok) {
			console.log("smith: " + made.error);
			return 2;
		}
		ensureDir(outDir);
		for (const file of made.value) { writeFile(outDir + "/" + file.name, file.text); }
		console.log("smith: wrote " + String(made.value.length) + " files to " + outDir);
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
		if (f.plant == Plant.San && !san) {
			console.log("smith: plant=san writes freed memory, which only the SAN lane judges; add --san");
			return 2;
		}
		return runSeeds(first.value, n.value, f, swarmed, san);
	}
	if (positional.length == 3 && positional[0] == "cov") {
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
		if (f.modules > 0) {
			console.log("smith: cov measures single-file programs; drop modules=");
			return 2;
		}
		if (covMsc == "" || san) {
			console.log("smith: cov measures one instrumented compiler; give --msc=<path> and drop --san");
			return 2;
		}
		return coverSeeds(first.value, n.value, f, swarmed, covMsc);
	}
	if (positional.length == 2 && positional[0] == "rerun") {
		if (overlayText != "" || swarmed || san) {
			console.log("smith: rerun takes its features from the bundle; drop --features/--plant/--swarm/--san");
			return 2;
		}
		return rerunBundle(positional[1]);
	}
	if (positional.length == 3 && positional[0] == "diag" && positional[1] == "show") {
		const seed = seedOf(positional[2]);
		if (!seed.ok) {
			console.log("smith: " + seed.error);
			return 2;
		}
		const c = caseFor(seed.value);
		console.log("kind " + c.kind + " variant " + c.variant + " line " + String(c.line) + " col " + String(c.col) + " token '" + c.token + "'");
		console.log("expected: " + (c.message == "" ? "clean" : c.message));
		console.log("--- mutant");
		console.log(c.mutant.slice(c.mutant.indexOf("// diag "), c.mutant.length));
		return 0;
	}
	if (positional.length == 3 && positional[0] == "diag") {
		const first = seedOf(positional[1]);
		const n = count(positional[2], "count");
		if (!first.ok || !n.ok || n.value < 1) {
			console.log("smith: diag takes a first seed and a count of at least 1");
			return 2;
		}
		if (overlayText != "" || swarmed || san) {
			console.log("smith: diag builds on the default program; drop --features/--plant=/--swarm/--san");
			return 2;
		}
		return diagPlant ? runPlanted(first.value, n.value) : runDiag(first.value, n.value);
	}
	if (positional.length == 2 && positional[0] == "reduce") { return reduceInput(cwd().replaceAll("\\", "/"), positional[1], identityPath, jobs, cap); }
	if (positional.length == 3 && positional[0] == "interesting") { return interesting(positional[1], positional[2]); }
	return usage();
}

process.exit(main());
