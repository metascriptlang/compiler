import { execFileResult } from "std/process";
import { ensureDir, exists, isDir, readFile, remove, removeAll, writeFile } from "std/fs";
import { subjectMsc } from "./drive";
import {
	Identity, firstDiff, firstCompilerError, formatIdentity, hasCompilerError, hasLine, missingKeep, parseIdentity, throwLine,
} from "./identity";

const WATCHDOG: string = "my $t = shift; my $pid = fork; if (!$pid) { setpgrp(0, 0); exec @ARGV; exit 127; } $SIG{ALRM} = sub { kill 'TERM', -$pid; }; alarm $t; waitpid($pid, 0); exit($? >> 8);";

struct Ran {
	exit: int32;
	out: string;
	err: string;
}

struct Lane {
	built: boolean;
	buildLog: string;
	exit: int32;
	out: string;
	err: string;
	again: string;
}

function fail(msg: string): int32 {
	console.log("smith: " + msg);
	return 2;
}

function ran(cmd: string, args: string[], dir: string, seconds: int32): Ran {
	const r = execFileResult("perl", ["-e", WATCHDOG, String(seconds), cmd, ...args], dir);
	return { exit: r.started ? r.exitCode : 127, out: r.output, err: r.errorOutput };
}

function parentOf(file: string): string { return file.slice(0, file.lastIndexOf("/")); }

function lane(msc: string, file: string, target: string): Lane {
	const dir = parentOf(file);
	const bin = dir + (target == "js" ? "/cand.js" : "/cand.bin");
	if (exists(bin)) { remove(bin); }
	const flags = target == "js" ? ["--target=js"] : [];
	const b = ran(msc, ["build", file, ...flags, "--no-color", "--output=" + bin], dir, 180);
	const log = b.out + b.err;
	if (b.exit != 0 || !exists(bin)) { return { built: false, buildLog: log, exit: -1, out: "", err: "", again: "" }; }
	const r = target == "js" ? ran("node", [bin], dir, 30) : ran(bin, [], dir, 30);
	const second = target == "js" ? ran("node", [bin], dir, 30) : ran(bin, [], dir, 30);
	return { built: true, buildLog: log, exit: r.exit, out: r.out, err: r.err, again: second.out };
}

function describe(l: Lane): string {
	if (!l.built) { return "build fails: " + firstCompilerError(l.buildLog); }
	return l.exit == 0 ? "runs clean" : "exits " + String(l.exit) + " " + throwLine(l.err);
}

function judge(id: Identity, msc: string, file: string): string {
	const dir = parentOf(file);
	const text = readFile(file);
	if (!text.ok) { return "cannot read the candidate"; }
	const gone = missingKeep(id.keep, text.value);
	if (gone != "") { return "the pinned construct '" + gone + "' is gone"; }
	if (ran(msc, ["check", file, "--no-color"], dir, 60).exit != 0) { return "msc check rejects the candidate"; }
	const js = lane(msc, file, "js");
	if (id.mode == "js-throws") {
		if (!js.built) { return "JS " + describe(js); }
		if (js.exit == 0) { return "JS lane runs clean"; }
		if (!hasLine(js.err, id.symptom)) { return "JS lane fails differently: " + throwLine(js.err); }
		const c = lane(msc, file, "c");
		return c.built && c.exit == 0 ? "" : "lane split moved: C " + describe(c);
	}
	if (!js.built || js.exit != 0) { return "lane split moved: JS " + describe(js); }
	const c = lane(msc, file, "c");
	if (id.mode == "c-build") {
		if (c.built) { return "C build succeeds"; }
		return hasCompilerError(c.buildLog, id.symptom) ? "" : "C build fails differently: " + firstCompilerError(c.buildLog);
	}
	if (!c.built || c.exit != 0) { return "lane split moved: C " + describe(c); }
	if (c.out != c.again) { return "C output is not deterministic (an address or a race), so the split is not a finding"; }
	if (js.out != js.again) { return "JS output is not deterministic, so the split is not a finding"; }
	const d = firstDiff(c.out, js.out);
	if (d.label == "") { return "lanes agree"; }
	if (d.label != id.label) { return "outputs differ at '" + d.label + "', not '" + id.label + "'"; }
	return d.shape == id.shape ? "" : "outputs differ in a " + d.shape + " value (" + d.left + " vs " + d.right + "), not " + id.shape;
}

function infer(msc: string, file: string): Result<Identity, string> {
	const dir = parentOf(file);
	if (ran(msc, ["check", file, "--no-color"], dir, 60).exit != 0) { return Result.err("msc check rejects the input"); }
	const js = lane(msc, file, "js");
	const c = lane(msc, file, "c");
	const jsOk = js.built && js.exit == 0;
	const cOk = c.built && c.exit == 0;
	if (js.built && js.exit != 0 && cOk && throwLine(js.err) != "") {
		return Result.ok({ mode: "js-throws", symptom: throwLine(js.err), label: "", shape: "", keep: "" });
	}
	if (!c.built && jsOk && firstCompilerError(c.buildLog) != "") {
		return Result.ok({ mode: "c-build", symptom: firstCompilerError(c.buildLog), label: "", shape: "", keep: "" });
	}
	if (jsOk && cOk && firstDiff(c.out, js.out).label != "") {
		const d = firstDiff(c.out, js.out);
		return Result.ok({ mode: "split", symptom: "", label: d.label, shape: d.shape, keep: "" });
	}
	return Result.err("no single-lane finding to pin: C " + describe(c) + "; JS " + describe(js));
}

export function interesting(identityFile: string, file: string): int32 {
	const text = readFile(identityFile);
	if (!text.ok) { return fail("cannot read " + identityFile); }
	const id = parseIdentity(text.value);
	if (!id.ok) { return fail(id.error); }
	const msc = subjectMsc(parentOf(identityFile));
	const why = judge(id.value, msc == "" ? "msc" : msc, file);
	console.log(why == "" ? "interesting" : "not interesting: " + why);
	return why == "" ? 0 : 1;
}

function stemOf(path: string): string {
	const trimmed = path.endsWith("/") ? path.slice(0, path.length - 1) : path;
	const base = trimmed.slice(trimmed.lastIndexOf("/") + 1, trimmed.length);
	return base.endsWith(".ms") ? base.slice(0, base.length - 3) : base;
}

function plantKeep(bundle: string): string {
	const meta = readFile(bundle + "/meta.txt");
	if (!meta.ok) { return ""; }
	for (const line of meta.value.split("\n")) {
		if (line.startsWith("features: ") && line.contains("plant=") && !line.contains("plant=none")) { return "plantDelta"; }
	}
	return "";
}

export function reduceInput(root: string, input: string, identityPath: string, jobs: int32, capSeconds: int32): int32 {
	const source = isDir(input) ? input + "/program.ms" : input;
	const original = readFile(source);
	if (!original.ok) { return fail("cannot read " + source); }
	const msc = subjectMsc(root);
	if (msc == "") { return fail("no compiler under test: set MSC, build ./msc, or install msc"); }
	const out = root + "/out/smith/reduced/" + stemOf(input);
	if (out == source.slice(0, source.lastIndexOf("/")) || out + "/input.ms" == source) { return fail("input lives in the output directory " + out); }
	removeAll(out);
	ensureDir(out + "/work");
	writeFile(out + "/input.ms", original.value);
	const work = out + "/work/program.ms";
	writeFile(work, original.value);
	let id: Identity;
	if (identityPath != "") {
		const text = readFile(identityPath);
		if (!text.ok) { return fail("cannot read " + identityPath); }
		const parsed = parseIdentity(text.value);
		if (!parsed.ok) { return fail(identityPath + ": " + parsed.error); }
		id = parsed.value;
	} else {
		const inferred = infer(msc, out + "/input.ms");
		if (!inferred.ok) { return fail(inferred.error); }
		id = { ...inferred.value, keep: isDir(input) ? plantKeep(input) : "" };
	}
	writeFile(out + "/identity.txt", formatIdentity(id));
	console.log("smith reduce — " + source + " (" + String(original.value.byteLength) + " bytes), msc " + msc);
	console.log("  accepted identity (anything else is drift and is rejected):");
	for (const line of formatIdentity(id).trimEnd().split("\n")) { console.log("    " + line); }
	const start = judge(id, msc, work);
	if (start != "") { return fail("the input does not show its own identity: " + start); }
	const check = out + "/smith-check";
	const built = execFileResult(msc, ["build", root + "/tools/smith/main.ms", "--no-color", "--output=" + check], root);
	if (!built.started || built.exitCode != 0 || !exists(check)) { return fail("cannot build the predicate binary: " + built.output + built.errorOutput); }
	writeFile(out + "/interesting.sh", "#!/bin/sh\nexport MSC='" + msc + "'\nexec '" + check + "' interesting '" + out + "/identity.txt' \"$PWD/program.ms\" >/dev/null\n");
	const tool = execFileResult("chmod", ["+x", out + "/interesting.sh"]);
	if (!tool.started || tool.exitCode != 0) { return fail("chmod failed on interesting.sh"); }
	const t0 = performance.now();
	const r = execFileResult("perl", ["-e", WATCHDOG, String(capSeconds), "creduce", "--not-c", "--n", String(jobs), out + "/interesting.sh", "program.ms"], out + "/work");
	writeFile(out + "/creduce.log", r.output + r.errorOutput);
	const seconds = ((performance.now() - t0) / 1000.0) as int32;
	const reduced = readFile(work);
	if (!reduced.ok) { return fail("lost the working copy " + work); }
	writeFile(out + "/reduced.ms", reduced.value);
	const final = judge(id, msc, out + "/reduced.ms");
	console.log("  " + String(original.value.byteLength) + " → " + String(reduced.value.byteLength) + " bytes in " + String(seconds) + " s" +
		(r.exitCode == 0 ? "" : " (creduce stopped early, exit " + String(r.exitCode) + ": cap " + String(capSeconds) + " s or failure; log " + out + "/creduce.log)"));
	console.log("  reduced.ms " + (final == "" ? "still shows the identity" : "DOES NOT show the identity: " + final));
	console.log("  → " + out + "/reduced.ms");
	return final == "" ? 0 : 1;
}
