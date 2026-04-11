// Cache — ~/.metascript/cache path helpers.
// Pure functions for computing cache paths from package identities.
// Filesystem operations (download, extract, flock) land in later phases.
// See docs/PACKAGE.md for the cache layout specification.

import { getEnv } from "std/process";
import { exists } from "std/fs";

// --- Base path ---

// Returns the cache root: ~/.metascript/cache
// Uses $HOME environment variable. Returns empty string if HOME is not set.
export function cacheRoot(): string {
	const home = getEnv("HOME");
	if (home === "") return "";
	return home + "/.metascript/cache";
}

// --- Registry paths ---

// Extracted source path for a registry package.
// Example: registrySrcPath("cool-json", "1.2.3") → "~/.metascript/cache/src/cool-json@v1.2.3"
export function registrySrcPath(name: string, version: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/src/${name}@${version}`;
}

// Download tarball path for a registry package.
export function registryDownloadPath(name: string, version: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/download/registry/${name}/${version}.tar.gz`;
}

// --- Git paths ---

// Extracted source path for a git package.
// Example: gitSrcPath("github.com/acme/foo", "abc123def4") → "~/.metascript/cache/src/github.com/acme/foo@abc123def4"
export function gitSrcPath(url: string, commit: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/src/${url}@${commit}`;
}

// Download tarball path for a git package.
export function gitDownloadPath(url: string, commit: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/download/git/${url}/${commit}.tar.gz`;
}

// --- Cache check ---

// Check if a package is already extracted in the cache.
export function isCached(srcPath: string): boolean {
	if (srcPath === "") return false;
	return exists(srcPath);
}

// --- Inline tests ---

test "cacheRoot uses HOME" {
	const root = cacheRoot();
	assert root.length > 0;
	assert root.endsWith("/.metascript/cache");
}

test "registrySrcPath format" {
	const p = registrySrcPath("cool-json", "1.2.3");
	assert p.endsWith("/src/cool-json@1.2.3");
}

test "gitSrcPath format" {
	const p = gitSrcPath("github.com/acme/foo", "abc123");
	assert p.endsWith("/src/github.com/acme/foo@abc123");
}

test "registryDownloadPath format" {
	const p = registryDownloadPath("cool-json", "1.2.3");
	assert p.endsWith("/download/registry/cool-json/1.2.3.tar.gz");
}
