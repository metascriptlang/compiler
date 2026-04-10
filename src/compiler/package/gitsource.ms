// Git Source — well-known host detection + archive URL builder.
//
// For v1, we fetch git archives via HTTPS from well-known hosts.
// No git binary required. Supports: github.com, gitlab.com,
// bitbucket.org, codeberg.org. See docs/PACKAGE.md for design.

// --- Types ---

export interface HostConfig {
	host: string;          // "github.com"
	archivePattern: string; // URL template with {owner}, {repo}, {ref} placeholders
}

// --- Well-known hosts ---

// Archive URL patterns per host. Each pattern uses {path} for "owner/repo"
// and {ref} for the tag or commit SHA.
export const KNOWN_HOSTS: HostConfig[] = [
	{ host: "github.com",    archivePattern: "https://codeload.github.com/{path}/tar.gz/{ref}" },
	{ host: "gitlab.com",    archivePattern: "https://gitlab.com/{path}/-/archive/{ref}/{repo}-{ref}.tar.gz" },
	{ host: "bitbucket.org", archivePattern: "https://bitbucket.org/{path}/get/{ref}.tar.gz" },
	{ host: "codeberg.org",  archivePattern: "https://codeberg.org/{path}/archive/{ref}.tar.gz" },
];

// --- Host detection ---

// Find the HostConfig for a given URL like "github.com/owner/repo".
// Returns null if the host is not in KNOWN_HOSTS.
export function detectHost(url: string): HostConfig {
	// Extract host: everything before the first "/"
	let slashIdx = -1;
	let i = 0;
	while (i < url.length) {
		if (url.charAt(i) === "/") { slashIdx = i; i = url.length; }
		i = i + 1;
	}
	if (slashIdx < 0) return null as unknown as HostConfig;
	const host = url.slice(0, slashIdx);

	for (const hc of KNOWN_HOSTS) {
		if (hc.host === host) return hc;
	}
	return null as unknown as HostConfig;
}

// --- Archive URL construction ---

// Extract the repo name (last path segment) from a URL like "github.com/owner/repo".
function extractRepoName(url: string): string {
	let lastSlash = -1;
	let i = 0;
	while (i < url.length) {
		if (url.charAt(i) === "/") lastSlash = i;
		i = i + 1;
	}
	if (lastSlash < 0) return url;
	return url.slice(lastSlash + 1, url.length);
}

// Extract the path (everything after the host) from a URL like "github.com/owner/repo".
function extractPath(url: string): string {
	let slashIdx = -1;
	let i = 0;
	while (i < url.length) {
		if (url.charAt(i) === "/") { slashIdx = i; i = url.length; }
		i = i + 1;
	}
	if (slashIdx < 0) return "";
	return url.slice(slashIdx + 1, url.length);
}

// Simple string replace — replaces first occurrence of `from` with `to`.
function replaceFirst(s: string, from: string, to: string): string {
	let idx = -1;
	let i = 0;
	while (i <= s.length - from.length) {
		let match = true;
		let j = 0;
		while (j < from.length) {
			if (s.charAt(i + j) !== from.charAt(j)) { match = false; j = from.length; }
			j = j + 1;
		}
		if (match) { idx = i; i = s.length; }
		i = i + 1;
	}
	if (idx < 0) return s;
	return s.slice(0, idx) + to + s.slice(idx + from.length, s.length);
}

// Build the archive download URL for a given host, URL, and ref.
// url: "github.com/owner/repo"
// ref: "1.2.3" or 40-char SHA
// Returns the full HTTPS URL to download the tarball.
export function archiveUrl(hostConfig: HostConfig, url: string, gitRef: string): string {
	const path = extractPath(url);
	const repo = extractRepoName(url);
	let result = hostConfig.archivePattern;
	result = replaceFirst(result, "{path}", path);
	result = replaceFirst(result, "{ref}", gitRef);
	result = replaceFirst(result, "{ref}", gitRef);  // GitLab pattern has {ref} twice
	result = replaceFirst(result, "{repo}", repo);
	return result;
}

// --- Inline tests ---

test "detectHost github" {
	const h = detectHost("github.com/acme/foo");
	assert h !== null;
	assert h.host === "github.com";
}

test "detectHost gitlab" {
	const h = detectHost("gitlab.com/group/project");
	assert h !== null;
	assert h.host === "gitlab.com";
}

test "detectHost bitbucket" {
	const h = detectHost("bitbucket.org/team/repo");
	assert h !== null;
	assert h.host === "bitbucket.org";
}

test "detectHost codeberg" {
	const h = detectHost("codeberg.org/user/repo");
	assert h !== null;
	assert h.host === "codeberg.org";
}

test "detectHost unknown returns null" {
	assert detectHost("example.com/foo/bar") === null;
}

test "detectHost no slash returns null" {
	assert detectHost("github.com") === null;
}

test "archiveUrl github tag" {
	const h = detectHost("github.com/acme/foo");
	const url = archiveUrl(h, "github.com/acme/foo", "1.2.3");
	assert url === "https://codeload.github.com/acme/foo/tar.gz/1.2.3";
}

test "archiveUrl github SHA" {
	const h = detectHost("github.com/acme/foo");
	const url = archiveUrl(h, "github.com/acme/foo", "abc123");
	assert url === "https://codeload.github.com/acme/foo/tar.gz/abc123";
}

test "archiveUrl gitlab" {
	const h = detectHost("gitlab.com/group/project");
	const url = archiveUrl(h, "gitlab.com/group/project", "2.0.0");
	assert url === "https://gitlab.com/group/project/-/archive/2.0.0/project-2.0.0.tar.gz";
}

test "archiveUrl bitbucket" {
	const h = detectHost("bitbucket.org/team/repo");
	const url = archiveUrl(h, "bitbucket.org/team/repo", "1.0.0");
	assert url === "https://bitbucket.org/team/repo/get/1.0.0.tar.gz";
}

test "archiveUrl codeberg" {
	const h = detectHost("codeberg.org/user/repo");
	const url = archiveUrl(h, "codeberg.org/user/repo", "0.1.0");
	assert url === "https://codeberg.org/user/repo/archive/0.1.0.tar.gz";
}

test "extractRepoName simple" {
	assert extractRepoName("github.com/acme/foo") === "foo";
}

test "extractRepoName deep path" {
	assert extractRepoName("gitlab.com/org/subgroup/repo") === "repo";
}
