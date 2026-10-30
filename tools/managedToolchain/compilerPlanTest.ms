import { CompilePlan, parseCompileArguments } from "./compilerPlan";

const MINIMAL: string[] = [
	"-target", "t",
	"-Xclang", "-target-cpu", "-Xclang", "c",
	"-isystem", "/a",
];
const MINIMAL_PLAN: CompilePlan = {
	target: "t",
	cpu: "c",
	pic: [],
	defines: [],
	features: [],
	isystem: ["/a"],
};
const WASI: string[] = [
	"zig", "clang", "/fx/runtimeWasi.c", "--no-default-config",
	"-target", "wasm32-unknown-wasi0.1.0-unknown",
	"-fno-PIE", "-fno-PIC", "-MD", "-nostdinc", "-DNDEBUG",
	"-isystem", "/z/lib/include",
	"-isystem", "/z/lib/libc/include/wasm-wasi-musl",
	"-isystem", "/z/lib/libc/include/generic-musl",
	"-isystem", "/z/lib/libc/include/any-wasi-any",
	"-O2",
	"-Xclang", "-target-cpu", "-Xclang", "lime1",
	"-Xclang", "-target-feature", "-Xclang", "-atomics",
	"-Xclang", "-target-feature", "-Xclang", "+sign-ext",
	"-c", "-o", "/tmp/x.o",
];
const LINUX: string[] = [
	"zig", "clang", "/fx/runtimeLinux.c", "--no-default-config",
	"-target", "x86_64-unknown-linux5.10.0-gnu2.31.0",
	"-fno-PIE", "-fPIC", "-MD", "-nostdinc", "-DNDEBUG",
	"-D__GLIBC_MINOR__=31",
	"-isystem", "/z/lib/include",
	"-isystem", "/z/lib/libc/include/x86_64-linux-gnu",
	"-O2",
	"-Xclang", "-target-cpu", "-Xclang", "x86-64",
	"-c", "-o", "/tmp/x.o",
];
let cases: int32 = 0;

function sameList(label: string, actual: string[], expected: string[]): void {
	if (actual.length != expected.length) {
		throw new Error(
			label + " count " + String(actual.length) + " != " +
				String(expected.length),
		);
	}
	for (let i: int32 = 0; i < expected.length; i += 1) {
		if (actual[i] != expected[i]) {
			throw new Error(
				label + "[" + String(i) + "] " + actual[i] + " != " +
					expected[i],
			);
		}
	}
}

function expectPlan(tokens: string[], expected: CompilePlan): void {
	const result = parseCompileArguments(tokens);
	if (!result.ok) { throw new Error(result.error); }
	const actual = result.value;
	if (actual.target != expected.target) {
		throw new Error("target " + actual.target + " != " + expected.target);
	}
	if (actual.cpu != expected.cpu) {
		throw new Error("cpu " + actual.cpu + " != " + expected.cpu);
	}
	sameList("pic", actual.pic, expected.pic);
	sameList("defines", actual.defines, expected.defines);
	sameList("features", actual.features, expected.features);
	sameList("isystem", actual.isystem, expected.isystem);
	cases += 1;
}

function expectRefusal(tokens: string[], message: string): void {
	const result = parseCompileArguments(tokens);
	if (result.ok) { throw new Error("accepted: " + message); }
	if (result.error != message) {
		throw new Error(result.error + " != " + message);
	}
	cases += 1;
}

function run(): void {
	expectPlan(WASI, {
		target: "wasm32-unknown-wasi0.1.0-unknown",
		cpu: "lime1",
		pic: ["-fno-PIE", "-fno-PIC"],
		defines: [],
		features: ["-atomics", "+sign-ext"],
		isystem: [
			"/z/lib/include",
			"/z/lib/libc/include/wasm-wasi-musl",
			"/z/lib/libc/include/generic-musl",
			"/z/lib/libc/include/any-wasi-any",
		],
	});
	expectPlan(LINUX, {
		target: "x86_64-unknown-linux5.10.0-gnu2.31.0",
		cpu: "x86-64",
		pic: ["-fno-PIE", "-fPIC"],
		defines: ["-D__GLIBC_MINOR__=31"],
		features: [],
		isystem: ["/z/lib/include", "/z/lib/libc/include/x86_64-linux-gnu"],
	});
	expectPlan(MINIMAL, MINIMAL_PLAN);

	for (const flag of [
		"-fno-PIE", "-fPIE", "-fno-PIC", "-fPIC",
		"-fno-pie", "-fpie", "-fno-pic", "-fpic",
	]) {
		expectPlan([...MINIMAL, flag], { ...MINIMAL_PLAN, pic: [flag] });
	}
	expectPlan(
		[
			...MINIMAL, "-fPIC=1", "-fpie2", "-FPIC", "-fPic",
			"-fvisibility=hidden", "-fno-PIE-x",
		],
		MINIMAL_PLAN,
	);

	expectPlan([...MINIMAL, "-DNDEBUG"], MINIMAL_PLAN);
	expectPlan(
		[
			...MINIMAL, "-DNDEBUG=1", "-D", "-DNDEBUGX", "-dFOO", "-UFOO",
			"-DA=b",
		],
		{ ...MINIMAL_PLAN, defines: ["-DNDEBUG=1", "-D", "-DNDEBUGX", "-DA=b"] },
	);
	expectPlan(
		[...MINIMAL, "-DB", "-DA", "-DB"],
		{ ...MINIMAL_PLAN, defines: ["-DB", "-DA", "-DB"] },
	);
	expectPlan(
		[...MINIMAL, "-isystem", "/b", "-isystem", "/a", "-isystem", "/b"],
		{ ...MINIMAL_PLAN, isystem: ["/a", "/b", "/a", "/b"] },
	);
	expectPlan(
		[
			...MINIMAL,
			"-Xclang", "-target-feature", "-Xclang", "+x",
			"-Xclang", "-target-feature", "-Xclang", "-y",
			"-Xclang", "-target-feature", "-Xclang", "+x",
		],
		{ ...MINIMAL_PLAN, features: ["+x", "-y", "+x"] },
	);
	expectPlan(
		[...MINIMAL, "-fPIC", "-fPIC", "-fno-PIC"],
		{ ...MINIMAL_PLAN, pic: ["-fPIC", "-fPIC", "-fno-PIC"] },
	);

	expectPlan(
		[
			"-target", "first",
			"-Xclang", "-target-cpu", "-Xclang", "first",
			...MINIMAL,
		],
		MINIMAL_PLAN,
	);
	expectPlan(
		[
			...MINIMAL,
			"-target", "u",
			"-Xclang", "-target-cpu", "-Xclang", "d",
		],
		{ ...MINIMAL_PLAN, target: "u", cpu: "d" },
	);

	expectPlan(
		[
			"-DA", "-isystem", "/x", "-fPIC",
			"-Xclang", "-target-feature", "-Xclang", "+f1",
			"-target", "T",
			"-isystem", "/y", "-DB",
			"-Xclang", "-target-cpu", "-Xclang", "K",
			"-fno-PIC",
			"-Xclang", "-target-feature", "-Xclang", "-f2",
		],
		{
			target: "T",
			cpu: "K",
			pic: ["-fPIC", "-fno-PIC"],
			defines: ["-DA", "-DB"],
			features: ["+f1", "-f2"],
			isystem: ["/x", "/y"],
		},
	);

	expectPlan(
		[
			...MINIMAL, "-O2", "-c", "-o", "/tmp/x.o", "-MD", "-Xclang",
			"-fcolor", "-Xclang", "-target-abi", "-Xclang", "x",
			"-target-cpu", "-target-feature", "a.c", "-isysroot", "/s",
			"-isystem-after", "-target-os", "-targetx", "-Xclang",
		],
		MINIMAL_PLAN,
	);

	expectPlan(
		[...MINIMAL, "-isystem", "-fPIC", "-isystem", "-DX"],
		{ ...MINIMAL_PLAN, isystem: ["/a", "-fPIC", "-DX"] },
	);
	expectPlan(
		[
			"-target", "-DFOO",
			"-Xclang", "-target-cpu", "-Xclang", "-DBAR",
			"-Xclang", "-target-feature", "-Xclang", "-fPIC",
			"-isystem", "/a",
		],
		{ ...MINIMAL_PLAN, target: "-DFOO", cpu: "-DBAR", features: ["-fPIC"] },
	);
	expectPlan(
		[...MINIMAL, "-isystem", "/a b/c d"],
		{ ...MINIMAL_PLAN, isystem: ["/a", "/a b/c d"] },
	);

	const surrounded = [
		"-isystem", "/outside", ...MINIMAL, "-isystem", "/after",
	];
	const viewed = parseCompileArguments(surrounded[2..10]);
	if (!viewed.ok) { throw new Error(viewed.error); }
	sameList("viewed isystem", viewed.value.isystem, ["/a"]);
	cases += 1;

	const input = [...LINUX];
	const parsed = parseCompileArguments(input);
	if (!parsed.ok) { throw new Error(parsed.error); }
	sameList("input", input, LINUX);
	cases += 1;

	expectRefusal([], "compile arguments have no -target");
	expectRefusal(
		["-Xclang", "-target-cpu", "-Xclang", "c", "-isystem", "/a"],
		"compile arguments have no -target",
	);
	expectRefusal(
		["-target", "t", "-isystem", "/a"],
		"compile arguments have no -target-cpu",
	);
	expectRefusal(
		["-target", "t", "-Xclang", "-target-cpu", "-Xclang", "c"],
		"compile arguments have no -isystem",
	);
	expectRefusal(
		[
			"-target", "t", "-isystem", "/a",
			"-Xclang", "-target-feature", "-Xclang", "+x",
		],
		"compile arguments have no -target-cpu",
	);

	expectRefusal(["-target"], "tokens[0]: -target has no value");
	expectRefusal(
		[...MINIMAL, "-target"],
		"tokens[8]: -target has no value",
	);
	expectRefusal(
		[...MINIMAL, "-isystem"],
		"tokens[8]: -isystem has no value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-cpu"],
		"tokens[8]: -Xclang -target-cpu is not followed by -Xclang and a value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-cpu", "-Xclang"],
		"tokens[8]: -Xclang -target-cpu is not followed by -Xclang and a value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-feature"],
		"tokens[8]: -Xclang -target-feature is not followed by -Xclang and a " +
			"value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-feature", "-Xclang"],
		"tokens[8]: -Xclang -target-feature is not followed by -Xclang and a " +
			"value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-cpu", "x", "y"],
		"tokens[8]: -Xclang -target-cpu is not followed by -Xclang and a value",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-feature", "-isystem", "/b"],
		"tokens[8]: -Xclang -target-feature is not followed by -Xclang and a " +
			"value",
	);

	expectRefusal(
		[...MINIMAL, "-target", ""],
		"tokens[8]: -target value is empty",
	);
	expectRefusal(
		[...MINIMAL, "-isystem", ""],
		"tokens[8]: -isystem value is empty",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-cpu", "-Xclang", ""],
		"tokens[8]: -Xclang -target-cpu value is empty",
	);
	expectRefusal(
		[...MINIMAL, "-Xclang", "-target-feature", "-Xclang", ""],
		"tokens[8]: -Xclang -target-feature value is empty",
	);
	expectRefusal(
		["-target", "", "-isystem"],
		"tokens[0]: -target value is empty",
	);

	console.log("compilerPlan: " + String(cases) + " cases OK");
}

when (!testBuild) { run(); }
