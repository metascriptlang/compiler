// createHash and createHmac with an algorithm the module does not know throw an error naming it (they returned a
// handle-less object whose digest() was "" before); a known algorithm still works.
//
// @stdout: createHash sha999: createHash: unsupported algorithm "sha999"
// @stdout: createHmac sha999: createHmac: unsupported algorithm "sha999"
// @stdout: createHash empty: createHash: unsupported algorithm ""
// @stdout: sha256 b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9
// @exit: 0
// @skip-js: std/crypto has only a C backend (index.cms over runtime/crypto); there is no index.jms
// @skip-raiser: std/crypto has only a C backend (index.cms over runtime/crypto); there is no raiser random

import { createHash, createHmac } from "std/crypto";

function attempt(label: string, make: () => void): void {
	try {
		make();
		console.log(`${label}: no error`);
	} catch (e) {
		console.log(`${label}: ${(e as Error).message}`);
	}
}

attempt("createHash sha999", () => { createHash("sha999"); });
attempt("createHmac sha999", () => { createHmac("sha999", "key"); });
attempt("createHash empty", () => { createHash(""); });
console.log(`sha256 ${createHash("sha256").update("hello world").digest("hex")}`);
