// Minimal JSON field extraction — shared by login.ms, publish.ms, and any
// future package-manager code that parses registry JSON responses.
//
// This is a hand-rolled scanner, NOT a full JSON parser. It handles the
// registry's flat string-valued fields ("key":"value") which is all we need
// for extracting tokens, usernames, URLs, and error messages from responses.

// Extract a string-valued field from a JSON string. Returns "" if not found.
// Only handles flat "key":"value" pairs — does not recurse into nested objects.
export function extractJsonField(json: string, field: string): string {
	const needle = "\"" + field + "\":\"";
	let idx = 0;
	while (idx <= json.length - needle.length) {
		let match = true;
		let j = 0;
		while (j < needle.length) {
			if (json.charAt(idx + j) != needle.charAt(j)) { match = false; j = needle.length; }
			j = j + 1;
		}
		if (match) {
			const start = idx + needle.length;
			let end = start;
			while (end < json.length && json.charAt(end) != "\"") end = end + 1;
			return json.slice(start, end);
		}
		idx = idx + 1;
	}
	return "";
}

// ===== Tests =====

test "extractJsonField basic" {
	const json = "{\"version\":\"1.2.3\",\"url\":\"https://example.com\"}";
	assert extractJsonField(json, "version") == "1.2.3";
	assert extractJsonField(json, "url") == "https://example.com";
	assert extractJsonField(json, "missing") == "";
}

test "extractJsonField nested ignored" {
	const json = "{\"outer\":{\"inner\":\"deep\"},\"top\":\"val\"}";
	assert extractJsonField(json, "top") == "val";
}

test "extractJsonField empty string value" {
	const json = "{\"token\":\"\"}";
	assert extractJsonField(json, "token") == "";
}
