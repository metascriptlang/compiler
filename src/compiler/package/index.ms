// Package Manager — public hub.
//
// Re-exports the package manager API. Individual submodules live in sibling
// files (version, mvs, manifest, lockfile, cache, registry, auth, etc.) and
// are wired up as the package manager commands (msc add, install, publish)
// are implemented.
//
// Importing this hub from src/index.ms ensures the submodules' inline tests
// are discovered by the main test runner (bun run test-ms src/index.ms).

export {
	ParsedVersion,
	parseVersion,
	isValidVersion,
	compareVersions,
	compareVersionStrings,
	maxVersion,
	SourceKind,
	ParsedGitSpec,
	parseGitSpec,
	parseSourceSpec,
} from "./version";

export {
	DepEntry,
	BuildListEntry,
	mvsResolve,
	findInBuildList,
} from "./mvs";

export {
	HostConfig,
	KNOWN_HOSTS,
	detectHost,
	archiveUrl,
} from "./gitsource";

export {
	LockEntry,
	Lockfile,
	readLockfile,
	writeLockfile,
	findEntry,
	entryName,
} from "./lockfile";

export {
	cacheRoot,
	registrySrcPath,
	registryDownloadPath,
	gitSrcPath,
	gitDownloadPath,
	isCached,
} from "./cache";

export { cmdAdd } from "./add";
export { cmdRemove } from "./remove";
export { cmdInstall } from "./install";
export { cmdLogin, cmdLogout, cmdWhoami } from "./login";
export { cmdPublish } from "./publish";
export { addDepToManifest, removeDepFromManifest, readManifest } from "./manifest";
