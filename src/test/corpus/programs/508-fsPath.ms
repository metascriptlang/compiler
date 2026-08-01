// @ledger-slack(msRefArrayRefCell): 1
// Prelude init RefCell array never destroyed at exit — TESTGAP T6 (probed:
// a bare console.log program shows 1/0; same global 302/410/505/506 slack).
// Parity program — std fs pure-string surface, ALL lanes incl. js: path
// manipulation (dirname/basename/extname/join/normalize/resolve/isAbsolute
// via the std/fs facade, relative via std/fs/path) and glob matching
// (std/fs/glob — compileGlob/globMatch/compileGlobs/globMatchAny). No I/O,
// no argv — output is a pure function of the source.

import { dirname, basename, extname, join, resolve, isAbsolute, normalize } from "std/fs";
import { relative } from "std/fs/path";
import { compileGlob, compileGlobs, globMatch, globMatchAny } from "std/fs/glob";

function flag(b: boolean): string {
	return b ? "y" : "n";
}

function main(): void {
	const paths: string[] = [
		"/usr/local/bin/msc",
		"src/parser/core.ms",
		"C:\\Users\\dev\\file.txt",
		"//server/share/data.bin",
		"/trailing/dir/",
		".hidden",
		"noext",
		"a.tar.gz",
	];
	for (const p of paths) {
		console.log("dir(" + p + ")=" + dirname(p));
		console.log("base(" + p + ")=" + basename(p));
		console.log("ext(" + p + ")=" + extname(p));
		console.log("abs(" + p + ")=" + flag(isAbsolute(p)));
	}

	console.log("join1=" + join("a/b", "c/d"));
	console.log("join2=" + join("a/b/", "c"));
	console.log("join3=" + join("a", "/rooted"));
	console.log("join4=" + join("", "x"));
	console.log("join5=" + join("a", ""));

	console.log("norm1=" + normalize("a/b/../c/./d"));
	console.log("norm2=" + normalize("/a//b///c"));
	console.log("norm3=" + normalize("../x/../y"));
	console.log("norm4=" + normalize("C:\\a\\..\\b"));
	console.log("norm5=" + normalize("//server/share/../other"));

	console.log("res1=" + resolve("x/y", "/base/dir"));
	console.log("res2=" + resolve("/already/abs", "/base"));
	console.log("res3=" + resolve("../up", "/base/dir"));

	console.log("rel1=" + relative("/a/b/c", "/a/b/d/e"));
	console.log("rel2=" + relative("/a/b", "/a/b"));
	console.log("rel3=" + relative("/a/b", "/a/b/c/d"));

	const g1 = compileGlob("*.ms");
	if (!g1.ok) { console.log("g1=compileFail"); return; }
	console.log("g1a=" + flag(globMatch(g1.value, "core.ms")));
	console.log("g1b=" + flag(globMatch(g1.value, "src/core.ms")));
	console.log("g1c=" + flag(globMatch(g1.value, "core.txt")));

	const g2 = compileGlob("src/**/*.c");
	if (!g2.ok) { console.log("g2=compileFail"); return; }
	console.log("g2a=" + flag(globMatch(g2.value, "src/out/main.c")));
	console.log("g2b=" + flag(globMatch(g2.value, "src/a/b/deep.c")));
	console.log("g2c=" + flag(globMatch(g2.value, "other/main.c")));

	const g3 = compileGlob("file?.txt");
	if (!g3.ok) { console.log("g3=compileFail"); return; }
	console.log("g3a=" + flag(globMatch(g3.value, "file1.txt")));
	console.log("g3b=" + flag(globMatch(g3.value, "file12.txt")));

	const gs = compileGlobs(["*.ms", "*.cms", "docs/*.md"]);
	console.log("gsCount=" + gs.globs.length.toString());
	console.log("gsa=" + flag(globMatchAny(gs.globs, "lexer.cms")));
	console.log("gsb=" + flag(globMatchAny(gs.globs, "docs/LANG.md")));
	console.log("gsc=" + flag(globMatchAny(gs.globs, "src/lexer.ms")));
}

main();
