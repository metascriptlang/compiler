// Parity program — `extern struct S from "struct T" { fields }` names a C struct tag and declares
// only the fields the program reads: the header owns the layout, so no struct is emitted, a value
// is `struct T`, a field reads by its C name (macOS `st_mtime` is a macro), and `sizeof S` is C's.
// Axes: `struct stat` through `stat`, `struct dirent` through `readdir` (a pointer to the struct),
// and a struct whose declared fields are a non-prefix subset in another order, copied by value
// and passed to MetaScript and C as a pointer. A struct named by its C typedef takes its size from C the same way.
//
// @skip-js: `extern function` binds a C symbol; the JS backend has no C linkage
// @xfail(raiser): raiser runtime error: Unknown host function: corpus1140MakeDir
// @stdout: dir true | file 6 true | missing|f.txt
// @stdout: 15 8 2 1 23 800 true true
// @exit: 0

@include("./tag.h");

extern struct Stat from "struct stat" {
	st_mode: uint32;
	st_size: int64;
	st_mtime: int64;
}
extern struct Dirent from "struct dirent" {
	d_name: cstring;
}
extern struct DIR;
extern struct Corpus1140Pair {
	c: int32;
}
extern struct Rec from "struct Corpus1140Rec" {
	Flag: uint8;
	tailVal: int32;
	ratio: float64;
}

extern function cStat(path: cstring, ref buf: Stat): int32 from "stat";
extern function opendir(path: cstring): Ptr<DIR>;
extern function readdir(d: Ptr<DIR>): Ptr<Dirent>;
extern function closedir(d: Ptr<DIR>): int32;
extern function corpus1140MakeDir(): cstring;
extern function corpus1140RemoveDir(): void;
extern function corpus1140RecFill(r: Ptr<Rec>, k: int32): void;
extern function corpus1140RecHead(r: Ptr<Rec>): int64;
extern function corpus1140RecSize(): int64;
extern function corpus1140PairSize(): int64;

function kind(path: string): string {
	let st: Stat = { st_mode: 0, st_size: 0, st_mtime: 0 };
	if (cStat(path as cstring, st) != 0) return "missing";
	if ((st.st_mode & 0o170000) == 0o040000) return `dir ${st.st_mtime > 0}`;
	return `file ${st.st_size} ${st.st_mtime > 0}`;
}

function entries(path: string): string {
	const dir = opendir(path as cstring);
	const names: string[] = [];
	let e = readdir(dir);
	while (e != null) {
		const name = e.d_name as string;
		if (name != "." && name != "..") names.push(name);
		e = readdir(dir);
	}
	closedir(dir);
	return names.join(",");
}

function weight(r: Ptr<Rec>): number {
	return r.tailVal + r.Flag;
}

const root = corpus1140MakeDir() as string;
console.log(`${kind(root)} | ${kind(`${root}/f.txt`)} | ${kind(`${root}/none`)}|${entries(root)}`);
corpus1140RemoveDir();

let r: Rec = { Flag: 0, tailVal: 0, ratio: 0 };
corpus1140RecFill(r as Ptr<Rec>, 8);
let copy = r;
r.tailVal = 1;
console.log(`${copy.tailVal} ${copy.Flag} ${copy.ratio} ${r.tailVal} ${weight(copy as Ptr<Rec>)} ${corpus1140RecHead(copy as Ptr<Rec>)} ${sizeof Rec == corpus1140RecSize()} ${sizeof Corpus1140Pair == corpus1140PairSize()}`);
