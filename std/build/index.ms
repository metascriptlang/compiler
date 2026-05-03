export interface FmtConfig {
	printWidth?: int32;
	tabWidth?: int32;
	useTabs?: boolean;
	singleQuote?: boolean;
}

export interface CcTargetConfig {
	entry?: string;            // entry point override for this target
	compiler?: string;         // C compiler binary for this target (e.g. "x86_64-linux-gnu-gcc")
	flags?: string[];          // extra compile flags (optional, compiler handles defaults)
	linkFlags?: string[];      // extra link flags (optional, compiler handles defaults)
}

export interface CcConfig {
	compiler?: string;         // default C compiler binary (e.g. "clang", "gcc")
	flags?: string[];          // extra compile flags (optional)
	linkFlags?: string[];      // extra link flags (optional)
	targets?: { [key: string]: CcTargetConfig };  // per-target overrides keyed by "os-cpu"
}

// CPU names (Go convention): amd64, arm64, 386, riscv64
// OS names: linux, darwin, windows, freebsd

export interface ResolveConfig {
	alias?: { [key: string]: string };  // path aliases: { "@parser": "src/parser" }
}

// Package metadata — used by `msc publish` and shown on the registry.
// Only `name` and `version` are required for publishing; others are optional.
// Version format: "<major>.<minor>.<patch>[-<prerelease>]" (e.g. "1.2.3", "0.1.0-rc1").
// No range operators — every dep version is an exact minimum. See docs/PACKAGE.md.
export interface PackageMeta {
	name: string;               // lowercase [a-z][a-z0-9-]*(/[a-z][a-z0-9-]*)?
	version: string;            // "<M>.<m>.<p>[-pre]"
	description?: string;
	license?: string;           // SPDX identifier, e.g. "MIT", "Apache-2.0"
	repository?: string;        // git URL
	homepage?: string;
	keywords?: string[];
	author?: string;
}

export interface BuildConfig {
	entry?: string;
	root?: string;              // project root for non-relative imports (default: ".")
	resolve?: ResolveConfig;    // module resolution config
	fmt?: FmtConfig;
	cc?: CcConfig;

	// Package manager fields — see docs/PACKAGE.md for the full spec.
	// Registry dep: { "foo": "1.2.3" }  — exact minimum version (no ranges)
	// Git dep:      { "bar": "git:github.com/owner/repo@v1.0.0" }  — tag or 40-char SHA
	package?: PackageMeta;                      // project metadata for `msc publish`
	deps?: { [key: string]: string };           // runtime dependencies
	devDeps?: { [key: string]: string };        // dev-only dependencies (tests, tooling)
}
