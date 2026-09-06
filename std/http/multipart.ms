// std/http/multipart — RFC 7578 multipart/form-data body builder.
//
// Pure string construction; no externs. The caller supplies a boundary
// (a random token that must not appear in any part body). For robust
// boundary generation see std/crypto.randomBytes — the caller should
// hex-encode 16 random bytes to get a 32-char collision-resistant boundary.
//
// Usage:
//   const parts: MultipartPart[] = [
//     { name: "metadata", filename: "", contentType: "application/json", body: "{...}" },
//     { name: "tarball", filename: "pkg-1.0.0.tar.gz", contentType: "application/gzip", body: tarGzBytes },
//   ];
//   const mp = buildMultipart(parts, "----boundary-32-chars");
//   // mp.contentType → "multipart/form-data; boundary=----boundary-32-chars"
//   // mp.body        → full body string (byte-safe)

export interface MultipartPart {
	name: string;            // form field name (e.g. "metadata")
	filename: string;        // "" for non-file parts
	contentType: string;     // e.g. "application/json", "application/gzip"
	body: string;            // part body (byte-safe)
}

export interface MultipartResult {
	body: string;            // full multipart body
	contentType: string;     // full Content-Type header value (includes boundary)
}

// Build a multipart/form-data body. The caller is responsible for generating
// a `boundary` that does not appear inside any part body — typically a 32-char
// random hex string. This function does not generate randomness itself so it
// stays pure, with no crypto externs.
//
// Returns the assembled body and the full Content-Type header value.
export function buildMultipart(parts: MultipartPart[], boundary: string): MultipartResult {
	const CRLF = "\r\n";
	const dashBoundary = "--" + boundary;
	let out = "";

	for (const p of parts) {
		out = out + dashBoundary + CRLF;
		out = out + `Content-Disposition: form-data; name="${p.name}"`;
		if (p.filename != "") {
			// File part: filename + Content-Type (RFC 7578 §4.2)
			out = out + `; filename="${p.filename}"`;
			out = out + CRLF;
			out = out + "Content-Type: " + p.contentType + CRLF;
		} else {
			// Text field: no Content-Type (RFC 7578 §4.4)
			out = out + CRLF;
		}
		out = out + CRLF;
		out = out + p.body + CRLF;
	}
	// Closing boundary.
	out = out + dashBoundary + "--" + CRLF;

	return { body: out, contentType: "multipart/form-data; boundary=" + boundary };
}

// Returns true if `boundary` occurs as a full line anywhere inside any part's
// body — in which case the caller should pick a different boundary. Rare for
// random 32-char hex strings against binary data, but worth checking for
// all-text bodies.
export function boundaryCollides(parts: MultipartPart[], boundary: string): boolean {
	const marker = "--" + boundary;
	for (const p of parts) {
		if (p.body.indexOf(marker) >= 0) return true;
	}
	return false;
}

// ===== Tests =====

test "empty parts list" {
	const parts: MultipartPart[] = [];
	const r = buildMultipart(parts, "BOUNDARY123");
	// Just the closing boundary.
	assert r.body == "--BOUNDARY123--\r\n";
	assert r.contentType == "multipart/form-data; boundary=BOUNDARY123";
}

test "single text part" {
	const parts: MultipartPart[] = [
		{ name: "metadata", filename: "", contentType: "application/json", body: "{\"a\":1}" },
	];
	const r = buildMultipart(parts, "B");
	const expected =
		"--B\r\n" +
		"Content-Disposition: form-data; name=\"metadata\"\r\n" +
		"\r\n" +
		"{\"a\":1}\r\n" +
		"--B--\r\n";
	assert r.body == expected;
}

test "file part with filename" {
	const parts: MultipartPart[] = [
		{ name: "tarball", filename: "pkg-1.0.0.tar.gz", contentType: "application/gzip", body: "GZBYTES" },
	];
	const r = buildMultipart(parts, "B");
	const expected =
		"--B\r\n" +
		"Content-Disposition: form-data; name=\"tarball\"; filename=\"pkg-1.0.0.tar.gz\"\r\n" +
		"Content-Type: application/gzip\r\n" +
		"\r\n" +
		"GZBYTES\r\n" +
		"--B--\r\n";
	assert r.body == expected;
}

test "two parts (metadata + archive)" {
	const parts: MultipartPart[] = [
		{ name: "metadata", filename: "", contentType: "application/json", body: "{}" },
		{ name: "archive", filename: "p.zip", contentType: "application/zip", body: "XYZ" },
	];
	const r = buildMultipart(parts, "BB");
	const expected =
		"--BB\r\n" +
		"Content-Disposition: form-data; name=\"metadata\"\r\n" +
		"\r\n" +
		"{}\r\n" +
		"--BB\r\n" +
		"Content-Disposition: form-data; name=\"archive\"; filename=\"p.zip\"\r\n" +
		"Content-Type: application/zip\r\n" +
		"\r\n" +
		"XYZ\r\n" +
		"--BB--\r\n";
	assert r.body == expected;
}

test "content type includes boundary" {
	const parts: MultipartPart[] = [];
	const r = buildMultipart(parts, "abc123");
	assert r.contentType == "multipart/form-data; boundary=abc123";
}

test "binary-like body survives intact" {
	const parts: MultipartPart[] = [
		{ name: "data", filename: "x.bin", contentType: "application/octet-stream", body: "\x00\x01\x02\xff" },
	];
	const r = buildMultipart(parts, "B");
	// The 4 binary bytes should appear verbatim between the part header and CRLF terminator.
	const idx = r.body.indexOf("\x00\x01\x02");
	assert idx >= 0;
}

test "boundary collision detection" {
	const parts: MultipartPart[] = [
		{ name: "data", filename: "", contentType: "text/plain", body: "hello --COLLIDE world" },
	];
	assert boundaryCollides(parts, "COLLIDE");
	assert !boundaryCollides(parts, "SAFE123");
}
