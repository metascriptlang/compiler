import { compileToCWithStd, compileProjectToJSWithStd } from "../helpers";

const HEAD = "struct S { n: int32; name: string; }\n"
	+ "struct World { pets: S[]; k: int32; }\n"
	+ "struct World2 { pets: Vec<int32>; day: int32; }\n"
	+ "struct L { tags: Vec<int32>; n: int32; }\n"
	+ "struct Around { pets: Span<S>; base: int32; }\n";

const ARR = "let xs: S[] = [{ n: 1, name: \"a\" }];";
const VEC = "let xs: Vec<int32> = [11, 22];";
const BORROW = ["cannot borrow"];
const TICK = "async function tick(): Promise<int32> { return 1; }\n";

function errorsOf(source: string): string {
	const c = compileToCWithStd(source);
	const js = compileProjectToJSWithStd([{ entryPath: "test/viewPaths.ms", entrySource: source }], "test/viewPaths.ms");
	if (c.ok && !js.startsWith("ERROR:")) return "";
	if (!c.ok && js.startsWith("ERROR:")) return c.error + "\n" + js;
	return "backends disagree: " + (c.ok ? "C ok" : c.error) + " / " + js;
}

function program(decls: string, body: string): string {
	return HEAD + decls + `function run(): int32 { ${body} } run();`;
}

function refusal(source: string, needles: string[]): string {
	const errors = errorsOf(source);
	if (errors == "") return "compiled clean on C and JS";
	if (errors.startsWith("backends disagree")) return errors;
	for (const needle of needles) {
		if (errors.split(needle).length >= 3) return "";
	}
	return "refused for another reason: " + errors;
}

test "rule 1: a Vec local viewed and then pushed directly is refused" {
	const why = refusal(program("", `${VEC} const v: Span<int32> = xs; xs.push(33); return v[0];`), BORROW);
	assert why == "", why;
}

test "rule 1: a Vec local viewed and then reassigned is refused" {
	const why = refusal(program("", `${VEC} const v: Span<int32> = xs; xs = [7]; return v[0];`), BORROW);
	assert why == "", why;
}

test "rule 1: a Vec local viewed and then passed to a ref parameter is refused" {
	const decls = "function growV(ref a: Vec<int32>): void { a.push(9); }\n";
	const why = refusal(program(decls, `${VEC} const v: Span<int32> = xs; growV(xs); return v[0];`), BORROW);
	assert why == "", why;
}

test "rule 1: a ref argument counts as a change even when the callee never resizes, as the reference's var rule" {
	const decls = "function writeDay(ref w: World2, day: int32): void { w.day = day; }\n";
	const why = refusal(program(decls, "let w: World2 = { pets: [11], day: 0 }; const v: Span<int32> = w.pets; writeDay(w, 8); return v[0];"), BORROW);
	assert why == "", why;
}

test "rule 1: a Vec local viewed and then moved is refused" {
	const decls = "function eat(a: Vec<int32>): int32 { return a.length as int32; }\n";
	const why = refusal(program(decls, `${VEC} const v: Span<int32> = xs; const k = eat(move xs); return v[0] + k;`), BORROW);
	assert why == "", why;
}

test "rule 1: a closure defined after the view that pushes the Vec is refused when called" {
	const why = refusal(program("", `${VEC} const v: Span<int32> = xs; const add = (): void => { xs.push(33); }; add(); return v[0];`), BORROW);
	assert why == "", why;
}

test "rule 1: a closure defined before the view that pushes the Vec is refused when called" {
	const why = refusal(program("", `${VEC} const add = (): void => { xs.push(33); }; const v: Span<int32> = xs; add(); return v[0];`), BORROW);
	assert why == "", why;
}

test "rule 1: a Vec field of a struct local viewed and then pushed directly is refused" {
	const why = refusal(program("", "let w: L = { tags: [1, 2], n: 0 }; const v: Span<int32> = w.tags; w.tags.push(3); return v[0];"), BORROW);
	assert why == "", why;
}

test "rule 1: a by-value getter over a Vec field of a struct leaves the view legal" {
	const decls = "function petCount(this w: World2): int32 { return w.pets.length as int32; }\n";
	const errors = errorsOf(program(decls, "let w: World2 = { pets: [1, 2], day: 1 }; const v: Span<int32> = w.pets; const c = w.petCount(); return v[0] + c;"));
	assert errors == "", errors;
}

test "rule 1: a sibling field write leaves the Vec field view legal" {
	const errors = errorsOf(program("", "let w: World2 = { pets: [1, 2], day: 1 }; const v: Span<int32> = w.pets; w.day = 5; return v[0] + w.day;"));
	assert errors == "", errors;
}

test "rule 1: a slot write into the Vec field leaves the view legal" {
	const errors = errorsOf(program("", "let w: L = { tags: [1, 2], n: 0 }; const v: Span<int32> = w.tags; w.tags[0] = 9; return v[0];"));
	assert errors == "", errors;
}

test "rule 1: passing the Vec by value leaves the view legal" {
	const decls = "function count(xs: Vec<int32>): int32 { return xs.length as int32; }\n";
	const errors = errorsOf(program(decls, `${VEC} const v: Span<int32> = xs; const k = count(xs); return v[0] + k;`));
	assert errors == "", errors;
}

test "rule 2: a T[] local viewed and then passed to a function that pushes is refused" {
	const decls = "function grow2(a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n";
	const why = refusal(program(decls, `${ARR} const sp: Span<S> = xs; grow2(xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: a getter-shaped extension that pushes is refused while its field is viewed" {
	const decls = "function census(this w: World): int32 { w.pets.push({ n: 3, name: \"c\" }); return w.pets.length as int32; }\n";
	const why = refusal(program(decls, "const w: World = { pets: [{ n: 4, name: \"p\" }], k: 2 }; const sp: Span<S> = w.pets; const c = w.census(); return sp[0].n + c;"), BORROW);
	assert why == "", why;
}

test "rule 2: a class method that pushes its own T[] field is refused while the field is viewed" {
	const decls = "class Zoo { pets: S[] = []; add(): void { this.pets.push({ n: 3, name: \"z\" }); } }\n";
	const why = refusal(program(decls, "const z = new Zoo(); z.pets.push({ n: 1, name: \"a\" }); const sp: Span<S> = z.pets; z.add(); return sp[0].n;"), BORROW);
	assert why == "", why;
}

test "rule 2: a class method that pushes its own Vec field is refused while the field is viewed" {
	const decls = "class Tally { tags: Vec<int32> = []; add(): void { this.tags.push(7); } }\n";
	const why = refusal(program(decls, "const t = new Tally(); t.tags.push(1); const v: Span<int32> = t.tags; t.add(); return v[0];"), BORROW);
	assert why == "", why;
}

test "rule 2: a callee that resizes only through a nested call is refused" {
	const decls = "function grow2(a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n"
		+ "function outer(a: S[]): void { grow2(a); }\n";
	const why = refusal(program(decls, `${ARR} const sp: Span<S> = xs; outer(xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: a call through a function-typed local that receives the array is refused" {
	const decls = "function grow2(a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n";
	const why = refusal(program(decls, `${ARR} const sp: Span<S> = xs; const f: (a: S[]) => void = grow2; f(xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: a call through a function-typed parameter that receives the array is refused" {
	const decls = "function viaCallback(xs: S[], f: (a: S[]) => void): int32 { const sp: Span<S> = xs; f(xs); return sp[0].n; }\n";
	const why = refusal(program(decls, `${ARR} return viaCallback(xs, (a: S[]): void => { });`), BORROW);
	assert why == "", why;
}

test "rule 2: a callee that forwards the array to a function-typed parameter is refused" {
	const decls = "function applyTo(f: (a: S[]) => void, a: S[]): void { f(a); }\n"
		+ "function seeLen(a: S[]): void { }\n";
	const why = refusal(program(decls, `${ARR} const sp: Span<S> = xs; applyTo(seeLen, xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: a function stored in an interface field that receives the array is refused" {
	const decls = "interface Feeder { feed: (a: S[]) => void; }\n"
		+ "function grow2(a: S[]): void { a.push({ n: 2, name: \"g\" }); }\n";
	const why = refusal(program(decls, `${ARR} const feeder: Feeder = { feed: grow2 }; const sp: Span<S> = xs; feeder.feed(xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: an overridden class method that receives the array is refused" {
	const decls = "class Feed { feed(a: S[]): void { } }\n"
		+ "class Pusher extends Feed { feed(a: S[]): void { a.push({ n: 5, name: \"p\" }); } }\n";
	const why = refusal(program(decls, `${ARR} const feed: Feed = new Pusher(); const sp: Span<S> = xs; feed.feed(xs); return sp[0].n;`), BORROW);
	assert why == "", why;
}

test "rule 2: a getter that only reads the T[] field of a struct leaves the view legal" {
	const decls = "function petCount(this w: World): int32 { return w.pets.length as int32; }\n";
	const errors = errorsOf(program(decls, "const w: World = { pets: [{ n: 4, name: \"p\" }], k: 2 }; const sp: Span<S> = w.pets; const c = w.petCount(); return sp[0].n + c;"));
	assert errors == "", errors;
}

test "rule 2: a call whose arguments cannot reach the viewed array type leaves the view legal" {
	const decls = "function label(k: int32, name: string): int32 { return k + (name.length as int32); }\n";
	const errors = errorsOf(program(decls, `${ARR} const sp: Span<S> = xs; const t = label(1, "ab"); return sp[0].n + t;`));
	assert errors == "", errors;
}

test "rule 2: a struct argument with no viewed array type inside leaves the view legal" {
	const decls = "struct Pt { x: int32; y: int32; }\nfunction norm(p: Pt): int32 { return p.x + p.y; }\n";
	const errors = errorsOf(program(decls, `${ARR} const sp: Span<S> = xs; const t = norm({ x: 1, y: 2 }); return sp[0].n + t;`));
	assert errors == "", errors;
}

test "rule 2: a callee that resizes an array of another element type leaves the view legal" {
	const decls = "function pushInt(a: int32[]): void { a.push(1); }\n";
	const errors = errorsOf(program(decls, `${ARR} const sp: Span<S> = xs; const ints: int32[] = [3]; pushInt(ints); return sp[0].n + ints[0];`));
	assert errors == "", errors;
}

test "rule 2: a method called on a struct that holds the views leaves them legal" {
	const decls = "function first(this a: Around): S { return a.pets[0]; }\n";
	const errors = errorsOf(program(decls, "const world: World = { pets: [{ n: 4, name: \"p\" }], k: 2 }; const around: Around = { pets: world.pets, base: 1 }; const f = around.first(); return f.n + around.base;"));
	assert errors == "", errors;
}

test "rule 2: a view struct that also carries arrays of another type stays legal when a callee grows those" {
	const decls = "struct Config { log: int32[]; }\n"
		+ "struct Seen { pets: Span<S>; config: Config; }\n"
		+ "function note(s: Seen): void { s.config.log.push(1); }\n";
	const errors = errorsOf(program(decls, "const world: World = { pets: [{ n: 4, name: \"p\" }], k: 2 }; const config: Config = { log: [] }; const seen: Seen = { pets: world.pets, config: config }; note(seen); return seen.pets[0].n;"));
	assert errors == "", errors;
}

test "rule 2: a view struct that also carries the viewed array is refused when a callee grows it" {
	const decls = "struct Owner { pets: S[]; }\n"
		+ "struct Seen { pets: Span<S>; owner: Owner; }\n"
		+ "function grow3(s: Seen): void { s.owner.pets.push({ n: 2, name: \"g\" }); }\n";
	const why = refusal(program(decls, "const owner: Owner = { pets: [{ n: 4, name: \"p\" }] }; const seen: Seen = { pets: owner.pets, owner: owner }; grow3(seen); return seen.pets[0].n;"), BORROW);
	assert why == "", why;
}

test "rule 2: an array stored into another argument escapes, and a later call that grows it there is refused" {
	const decls = "class Registry { items: int32[][] = []; }\n"
		+ "function register(r: Registry, a: int32[]): void { r.items.push(a); }\n"
		+ "function growFirst(r: Registry): void { r.items[0].push(1); }\n";
	const why = refusal(program(decls, "const r = new Registry(); const a: int32[] = [11, 22]; register(r, a); const v: Span<int32> = a; growFirst(r); return v[0];"), BORROW);
	assert why == "", why;
}

test "rule 2: a slot write into the T[] leaves the view legal" {
	const errors = errorsOf(program("", `${ARR} const sp: Span<S> = xs; xs[0] = { n: 9, name: "z" }; return sp[0].n;`));
	assert errors == "", errors;
}

test "rule 2: a nested call chain that never resizes leaves the view legal" {
	const decls = "function innerRead(a: S[]): int32 { return a.length as int32; }\n"
		+ "function outerRead(a: S[]): int32 { return innerRead(a); }\n";
	const errors = errorsOf(program(decls, `${ARR} const sp: Span<S> = xs; const k = outerRead(xs); return sp[0].n + k;`));
	assert errors == "", errors;
}

test "rule 3: a view of a T[] parameter read after an await is refused" {
	const decls = "async function reads(xs: S[]): Promise<int32> { const sp: Span<S> = xs; const t = await tick(); return sp[0].n + t; }\n"
		+ "async function main(): Promise<int32> { const xs: S[] = [{ n: 1, name: \"a\" }]; return await reads(xs); }\nmain();";
	const why = refusal(HEAD + TICK + decls, BORROW);
	assert why == "", why;
}

test "rule 3: a view of a captured T[] read after an await is refused" {
	const decls = "async function main(): Promise<int32> {\n"
		+ "\tconst xs: S[] = [{ n: 1, name: \"a\" }];\n"
		+ "\tconst f = async (): Promise<int32> => { const sp: Span<S> = xs; const t = await tick(); return sp[0].n + t; };\n"
		+ "\treturn await f();\n}\nmain();";
	const why = refusal(HEAD + TICK + decls, BORROW);
	assert why == "", why;
}

test "rule 3: an async function with a Span parameter is refused" {
	const decls = "async function takes(sp: Span<S>): Promise<int32> { return sp[0].n; }\n"
		+ "async function main(): Promise<int32> { const xs: S[] = [{ n: 1, name: \"a\" }]; return await takes(xs); }\nmain();";
	const why = refusal(HEAD + TICK + decls, ["cannot borrow", "cannot be captured as it would violate memory safety"]);
	assert why == "", why;
}

test "rule 3: a Vec local view used across an await is legal when nothing captures the Vec" {
	const decls = "async function main(): Promise<int32> { let xs: Vec<int32> = [11, 22]; const v: Span<int32> = xs; const t = await tick(); return v[0] + t; }\nmain();";
	const errors = errorsOf(HEAD + TICK + decls);
	assert errors == "", errors;
}

test "rule 3: a struct that holds Span fields declared and used locally is legal" {
	const errors = errorsOf(program("", `${ARR} const around: Around = { pets: xs, base: 1 }; return around.pets[0].n + around.base;`));
	assert errors == "", errors;
}

test "module level: a view of a module-level Vec that is pushed afterwards is refused" {
	const why = refusal(`${HEAD}${VEC} const v: Span<int32> = xs; for (let i = 0; i < 100; i += 1) xs.push(i); console.log(v[0]);`, BORROW);
	assert why == "", why;
}

test "module level: a view of a module-level array grown through a call is refused" {
	const decls = "function growS(a: S[]): void { a.push({ n: 2, name: \"b\" }); }\n";
	const why = refusal(`${HEAD}${decls}${ARR} const sp: Span<S> = xs; growS(xs); console.log(sp[0].n);`, BORROW);
	assert why == "", why;
}

test "module level: a module-level view of a mutable module-level Vec is refused even when read before any change" {
	const why = refusal(`${HEAD}${VEC} const v: Span<int32> = xs; console.log(v[0]);`, BORROW);
	assert why == "", why;
}

test "module level: a module-level read-only view of a const sized array is legal" {
	const errors = errorsOf(`${HEAD}const fixed: int32[3] = [1, 2, 3]; const r: Readonly<Span<int32>> = fixed; console.log(r[2]);`);
	assert errors == "", errors;
}

test "module level: a view in a top-level block of a block-local Vec pushed afterwards is refused" {
	const why = refusal(`${HEAD}{ ${VEC} const v: Span<int32> = xs; xs.push(33); console.log(v[0]); }`, BORROW);
	assert why == "", why;
}

test "module level: a view in a top-level block read before the push is legal" {
	const errors = errorsOf(`${HEAD}{ ${VEC} const v: Span<int32> = xs; console.log(v[0]); xs.push(33); }`);
	assert errors == "", errors;
}

test "module level: a pointer to a mutable module-level struct is legal, at module level and inside a function" {
	const decls = "struct In { v: int32; }\nlet g: In = { v: 1 };\nconst gp = g as Ptr<In>;\nfunction readG(): int32 { const lp = g as Ptr<In>; g = { v: 2 }; return lp.v; }\n";
	const errors = errorsOf(`${HEAD}${decls}g = { v: 3 }; console.log(gp.v + readG());`);
	assert errors == "", errors;
}

test "module level: a pointer into an element of a module-level Vec is refused" {
	const why = refusal(`${HEAD}struct In { v: int32; }\nlet ps: Vec<In> = [{ v: 1 }];\nconst p = ps[0] as Ptr<In>;\nconsole.log(p.v);`, BORROW);
	assert why == "", why;
}

test "module level: a Borrow of a mutable module-level struct is refused" {
	const why = refusal(`${HEAD}struct In { v: int32; }\nlet g: In = { v: 1 };\nconst b: Borrow<In> = g;\nconsole.log(b.v);`, BORROW);
	assert why == "", why;
}

test "module level: a Borrow into an element of a const module-level shared array is refused" {
	const why = refusal(`${HEAD}const ns = [1, 2, 3];\nconst e: Borrow<int32> = ns[2];\nconsole.log(e);`, BORROW);
	assert why == "", why;
}

test "module level: a Borrow of a const module-level array handle or struct field is legal" {
	const decls = "struct Bag2 { items: int32[]; k: int32; }\nconst bag: Bag2 = { items: [4, 5], k: 1 };\nconst ns = [1, 2, 3];\n";
	const errors = errorsOf(`${HEAD}${decls}const bi: Borrow<int32[]> = bag.items; const bk: Borrow<int32> = bag.k; const bn: Borrow<int32[]> = ns; console.log(bi[1] + bk + bn[0]);`);
	assert errors == "", errors;
}
