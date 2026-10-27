import { env } from "std/process";
import { join } from "std/fs/path";
import { metascriptHome } from "./path";

let configuredLocalDir = "";
let configuredGlobalDir = "";
let configuredGlobalEnabled = true;

export function configureCachePaths(
	localDir: string,
	globalDir: string,
	globalEnabled: boolean,
): void {
	configuredLocalDir = localDir;
	configuredGlobalDir = globalDir;
	configuredGlobalEnabled = globalEnabled;
}

export function localCacheDir(release: boolean = false): string {
	if (configuredLocalDir != "") return configuredLocalDir;
	const envDir = env.get("MSC_CACHE_DIR");
	if (envDir != "") return envDir;
	return join(release ? "out/release" : "out/debug", ".cache");
}

export function globalCacheRoot(): string {
	if (!configuredGlobalEnabled || env.get("MSC_NO_GLOBAL_CACHE") != "") return "";
	if (configuredGlobalDir != "") return configuredGlobalDir;
	const envDir = env.get("MSC_GLOBAL_CACHE_DIR");
	if (envDir != "") return envDir;
	const home = metascriptHome();
	return home == "" ? "" : join(home, "cache");
}

when (testBuild) {
	struct CachePathsTestState {
		localDir: string;
		globalDir: string;
		globalEnabled: boolean;
		localEnv: string;
		globalEnv: string;
		disableEnv: string;
		homeEnv: string;
		profileEnv: string;
	}

	function saveCachePathsTestState(): CachePathsTestState {
		return {
			localDir: configuredLocalDir,
			globalDir: configuredGlobalDir,
			globalEnabled: configuredGlobalEnabled,
			localEnv: env.get("MSC_CACHE_DIR"),
			globalEnv: env.get("MSC_GLOBAL_CACHE_DIR"),
			disableEnv: env.get("MSC_NO_GLOBAL_CACHE"),
			homeEnv: env.get("HOME"),
			profileEnv: env.get("USERPROFILE"),
		};
	}

	function restoreCachePathsTestState(state: CachePathsTestState): void {
		configureCachePaths(state.localDir, state.globalDir, state.globalEnabled);
		env.set("MSC_CACHE_DIR", state.localEnv);
		env.set("MSC_GLOBAL_CACHE_DIR", state.globalEnv);
		env.set("MSC_NO_GLOBAL_CACHE", state.disableEnv);
		env.set("HOME", state.homeEnv);
		env.set("USERPROFILE", state.profileEnv);
	}

	function useFallbackCachePathsForTest(): void {
		configureCachePaths("", "", true);
		env.set("MSC_CACHE_DIR", "");
		env.set("MSC_GLOBAL_CACHE_DIR", "");
		env.set("MSC_NO_GLOBAL_CACHE", "");
		env.set("HOME", "");
		env.set("USERPROFILE", "");
	}

	test "localCacheDir defaults to separate debug and release roots" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			assert localCacheDir() == "out/debug/.cache";
			assert localCacheDir(false) == "out/debug/.cache";
			assert localCacheDir(true) == "out/release/.cache";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "localCacheDir standalone environment overrides both modes" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			env.set("MSC_CACHE_DIR", "/env/local");
			assert localCacheDir() == "/env/local";
			assert localCacheDir(true) == "/env/local";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "localCacheDir configured path wins over fallback environment" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			env.set("MSC_CACHE_DIR", "/env/local");
			configureCachePaths("/selected/local", "", true);
			assert localCacheDir() == "/selected/local";
			assert localCacheDir(true) == "/selected/local";
			configureCachePaths("", "", true);
			assert localCacheDir() == "/env/local";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot prefers HOME then USERPROFILE and otherwise has no default" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			assert globalCacheRoot() == "";
			env.set("USERPROFILE", "/profile");
			assert globalCacheRoot() == "/profile/.metascript/cache";
			env.set("HOME", "/home");
			assert globalCacheRoot() == "/home/.metascript/cache";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot standalone environment overrides home defaults" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			env.set("HOME", "/home");
			env.set("USERPROFILE", "/profile");
			env.set("MSC_GLOBAL_CACHE_DIR", "/env/global");
			assert globalCacheRoot() == "/env/global";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot configured path wins without HOME or USERPROFILE" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			env.delete("HOME");
			env.delete("USERPROFILE");
			env.set("MSC_GLOBAL_CACHE_DIR", "/env/global");
			configureCachePaths("", "/selected/global", true);
			assert globalCacheRoot() == "/selected/global";
			configureCachePaths("", "", true);
			assert globalCacheRoot() == "/env/global";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot configured false disables fallback environment and home" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			env.set("HOME", "/home");
			env.set("MSC_GLOBAL_CACHE_DIR", "/env/global");
			configureCachePaths("", "", false);
			assert globalCacheRoot() == "";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot configured false wins over a nonempty configured path" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			configureCachePaths("/selected/local", "/selected/global", false);
			assert globalCacheRoot() == "";
			assert localCacheDir() == "/selected/local";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}

	test "globalCacheRoot environment hard disable remains dynamic after configuration" {
		const saved = saveCachePathsTestState();
		try {
			useFallbackCachePathsForTest();
			configureCachePaths("", "/selected/global", true);
			assert globalCacheRoot() == "/selected/global";
			env.set("MSC_NO_GLOBAL_CACHE", "1");
			assert globalCacheRoot() == "";
			env.set("MSC_NO_GLOBAL_CACHE", "0");
			assert globalCacheRoot() == "";
			env.set("MSC_NO_GLOBAL_CACHE", "");
			assert globalCacheRoot() == "/selected/global";
		} finally {
			restoreCachePathsTestState(saved);
		}
	}
}
