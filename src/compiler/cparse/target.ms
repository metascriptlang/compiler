// cparse — Target model and predefined macros
// Not in chibicc (chibicc hardcodes x86-64 Linux ILP64).
// Parameterizes sizeof/alignof/struct layout so FFI bindings are correct
// across targets.

export enum TargetTriple {
	LinuxX86_64,
	LinuxAarch64,
	MacosX86_64,
	MacosAarch64,
	WindowsX64,
	Wasm32,
}

// All size/align values in bytes. Covers primitive C types whose sizes vary
// across targets. Types with fixed sizes (int32_t, etc.) aren't in this table.
export interface TargetInfo {
	triple: TargetTriple;
	tripleName: string;         // "x86_64-linux-gnu", etc.
	pointerSize: number;        // 4 or 8
	pointerAlign: number;
	shortSize: number;          // almost always 2
	intSize: number;            // 4 on all mainstream targets
	longSize: number;           // 4 on Windows LLP64, 8 on LP64
	longLongSize: number;       // 8 everywhere we care about
	floatSize: number;          // 4
	doubleSize: number;         // 8
	longDoubleSize: number;     // 8, 12, or 16 depending on target
	sizeTSigned: boolean;       // size_t signed? (no, but listed for completeness)
	charSigned: boolean;        // default signedness of bare `char`
}

export function targetLinuxX86_64(): TargetInfo {
	return {
		triple: TargetTriple.LinuxX86_64,
		tripleName: "x86_64-linux-gnu",
		pointerSize: 8, pointerAlign: 8,
		shortSize: 2, intSize: 4, longSize: 8, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 16,
		sizeTSigned: false, charSigned: true,
	};
}

export function targetLinuxAarch64(): TargetInfo {
	return {
		triple: TargetTriple.LinuxAarch64,
		tripleName: "aarch64-linux-gnu",
		pointerSize: 8, pointerAlign: 8,
		shortSize: 2, intSize: 4, longSize: 8, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 16,
		sizeTSigned: false, charSigned: false, // aarch64 char is unsigned
	};
}

export function targetMacosX86_64(): TargetInfo {
	return {
		triple: TargetTriple.MacosX86_64,
		tripleName: "x86_64-apple-darwin",
		pointerSize: 8, pointerAlign: 8,
		shortSize: 2, intSize: 4, longSize: 8, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 16,
		sizeTSigned: false, charSigned: true,
	};
}

export function targetMacosAarch64(): TargetInfo {
	return {
		triple: TargetTriple.MacosAarch64,
		tripleName: "arm64-apple-darwin",
		pointerSize: 8, pointerAlign: 8,
		shortSize: 2, intSize: 4, longSize: 8, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 8,
		sizeTSigned: false, charSigned: true,
	};
}

export function targetWindowsX64(): TargetInfo {
	return {
		triple: TargetTriple.WindowsX64,
		tripleName: "x86_64-pc-windows-msvc",
		pointerSize: 8, pointerAlign: 8,
		shortSize: 2, intSize: 4, longSize: 4, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 8,
		sizeTSigned: false, charSigned: true,
	};
}

export function targetWasm32(): TargetInfo {
	return {
		triple: TargetTriple.Wasm32,
		tripleName: "wasm32-unknown-unknown",
		pointerSize: 4, pointerAlign: 4,
		shortSize: 2, intSize: 4, longSize: 4, longLongSize: 8,
		floatSize: 4, doubleSize: 8, longDoubleSize: 8,
		sizeTSigned: false, charSigned: true,
	};
}

// Default host target for macOS arm64 (development machine)
export function defaultHostTarget(): TargetInfo {
	return targetMacosAarch64();
}

// Lookup by triple enum.
export function targetFromTriple(triple: TargetTriple): TargetInfo {
	return match (triple) {
		TargetTriple.LinuxX86_64 => targetLinuxX86_64(),
		TargetTriple.LinuxAarch64 => targetLinuxAarch64(),
		TargetTriple.MacosX86_64 => targetMacosX86_64(),
		TargetTriple.MacosAarch64 => targetMacosAarch64(),
		TargetTriple.WindowsX64 => targetWindowsX64(),
		TargetTriple.Wasm32 => targetWasm32(),
		_ => targetMacosAarch64(),
	};
}

// Parse a triple name string to a TargetTriple enum. Returns null-ish on unknown.
export function parseTripleName(name: string): TargetTriple {
	if (name === "x86_64-linux-gnu" || name === "linux-x86_64") return TargetTriple.LinuxX86_64;
	if (name === "aarch64-linux-gnu" || name === "linux-aarch64") return TargetTriple.LinuxAarch64;
	if (name === "x86_64-apple-darwin" || name === "macos-x86_64") return TargetTriple.MacosX86_64;
	if (name === "arm64-apple-darwin" || name === "macos-aarch64") return TargetTriple.MacosAarch64;
	if (name === "x86_64-pc-windows-msvc" || name === "windows-x64") return TargetTriple.WindowsX64;
	if (name === "wasm32-unknown-unknown" || name === "wasm32") return TargetTriple.Wasm32;
	return TargetTriple.MacosAarch64; // fallback to host
}

// Predefined macro as a (name, value) pair. The preprocessor ingests these
// before reading any source file so #if branches take the correct path.
export interface MacroDef {
	name: string;
	value: string;
}

function m(name: string, value: string): MacroDef {
	return { name, value };
}

// Predefined macros for a target. Minimal starter set — extend as real headers demand.
export function predefinedMacros(t: TargetInfo): MacroDef[] {
	const result: MacroDef[] = [
		m("__STDC__", "1"),
		m("__STDC_HOSTED__", "1"),
		m("__STDC_VERSION__", "201112L"),
	];
	match (t.triple) {
		TargetTriple.LinuxX86_64 => {
			result.push(m("__linux__", "1")); result.push(m("__unix__", "1")); result.push(m("__gnu_linux__", "1"));
			result.push(m("__x86_64__", "1")); result.push(m("__LP64__", "1")); result.push(m("_LP64", "1"));
			result.push(m("__GNUC__", "4")); result.push(m("__GNUC_MINOR__", "2"));
		},
		TargetTriple.LinuxAarch64 => {
			result.push(m("__linux__", "1")); result.push(m("__unix__", "1"));
			result.push(m("__aarch64__", "1")); result.push(m("__LP64__", "1"));
			result.push(m("__GNUC__", "4")); result.push(m("__GNUC_MINOR__", "2"));
		},
		TargetTriple.MacosX86_64 => {
			result.push(m("__APPLE__", "1")); result.push(m("__MACH__", "1")); result.push(m("__unix__", "1"));
			result.push(m("__x86_64__", "1")); result.push(m("__LP64__", "1"));
			result.push(m("__GNUC__", "4")); result.push(m("__GNUC_MINOR__", "2"));
		},
		TargetTriple.MacosAarch64 => {
			result.push(m("__APPLE__", "1")); result.push(m("__MACH__", "1")); result.push(m("__unix__", "1"));
			result.push(m("__aarch64__", "1")); result.push(m("__arm64__", "1")); result.push(m("__LP64__", "1"));
			result.push(m("__GNUC__", "4")); result.push(m("__GNUC_MINOR__", "2"));
		},
		TargetTriple.WindowsX64 => {
			result.push(m("_WIN32", "1")); result.push(m("_WIN64", "1")); result.push(m("WIN32", "1"));
			result.push(m("_MSC_VER", "1929")); result.push(m("_M_X64", "100")); result.push(m("_M_AMD64", "100"));
		},
		TargetTriple.Wasm32 => {
			result.push(m("__wasm__", "1")); result.push(m("__wasm32__", "1"));
		},
	};
	return result;
}

test "default host target is populated" {
	const t = defaultHostTarget();
	assert t.pointerSize === 8;
	assert t.intSize === 4;
}

test "windows x64 uses LLP64 long size" {
	const t = targetWindowsX64();
	assert t.longSize === 4;
	assert t.longLongSize === 8;
}

test "linux x86_64 predefined includes __LP64__" {
	const macros = predefinedMacros(targetLinuxX86_64());
	let found = false;
	for (const md of macros) {
		if (md.name === "__LP64__") found = true;
	}
	assert found;
}

test "linux aarch64 char is unsigned" {
	const t = targetLinuxAarch64();
	assert t.charSigned === false;
	assert t.longSize === 8;
}

test "macos x86_64 long double is 16" {
	const t = targetMacosX86_64();
	assert t.longDoubleSize === 16;
}

test "targetFromTriple round-trips" {
	const t = targetFromTriple(TargetTriple.WindowsX64);
	assert t.longSize === 4;
}

test "parseTripleName linux" {
	assert parseTripleName("linux-x86_64") === TargetTriple.LinuxX86_64;
	assert parseTripleName("x86_64-linux-gnu") === TargetTriple.LinuxX86_64;
}

test "parseTripleName wasm" {
	assert parseTripleName("wasm32") === TargetTriple.Wasm32;
}

test "all 6 triples have predefined macros" {
	assert predefinedMacros(targetLinuxX86_64()).length > 3;
	assert predefinedMacros(targetLinuxAarch64()).length > 3;
	assert predefinedMacros(targetMacosX86_64()).length > 3;
	assert predefinedMacros(targetMacosAarch64()).length > 3;
	assert predefinedMacros(targetWindowsX64()).length > 3;
	assert predefinedMacros(targetWasm32()).length > 3;
}
