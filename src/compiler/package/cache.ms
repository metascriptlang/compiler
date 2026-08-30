// Cache — ~/.metascript/cache path helpers.
// Pure functions for computing cache paths from package identities.
// Filesystem operations (download, extract, flock) land in later phases.
// See docs/PACKAGE.md for the cache layout specification.

import { env } from "std/process";
import { exists } from "std/fs";

// --- Base path ---

// Returns the cache root: ~/.metascript/cache
// Uses $HOME, falling back to $USERPROFILE (Windows does not set HOME by
// default — same pattern as cc.ms homeDir / cache.ms globalObjectsDir).
export function cacheRoot(): string {
	let home = env.get("HOME");
	if (home === "") home = env.get("USERPROFILE");
	if (home === "") return "";
	return home + "/.metascript/cache";
}

// --- Registry paths ---

// Extracted package path for a registry package.
// Example: registrySrcPath("cool-json", "1.2.3") → "~/.metascript/cache/extracted/cool-json@v1.2.3"
export function registrySrcPath(name: string, version: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/extracted/${name}@${version}`;
}

// Download archive path for a registry package.
export function registryDownloadPath(name: string, version: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/download/registry/${name}/${version}.zip`;
}

// --- Git paths ---

// Extracted package path for a git source.
// Example: gitSrcPath("github.com/acme/foo", "abc123def4") → "~/.metascript/cache/extracted/github.com/acme/foo@abc123def4"
export function gitSrcPath(url: string, commit: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/extracted/${url}@${commit}`;
}

// Download archive path for a git package.
export function gitDownloadPath(url: string, commit: string): string {
	const root = cacheRoot();
	if (root === "") return "";
	return `${root}/download/git/${url}/${commit}.zip`;
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
	assert p.endsWith("/extracted/cool-json@1.2.3");
}

test "gitSrcPath format" {
	const p = gitSrcPath("github.com/acme/foo", "abc123");
	assert p.endsWith("/extracted/github.com/acme/foo@abc123");
}

test "registryDownloadPath format" {
	const p = registryDownloadPath("cool-json", "1.2.3");
	assert p.endsWith("/download/registry/cool-json/1.2.3.zip");
}
