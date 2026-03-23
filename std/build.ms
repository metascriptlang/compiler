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

export interface BuildConfig {
	entry?: string;
	fmt?: FmtConfig;
	cc?: CcConfig;
}
