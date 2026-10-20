// @stdout: security.txt declared
// @skip-raiser: std/solana has memory and kernel modules for C and JS only
// note: a program that declares its security.txt block builds and runs on a host and on JS; the block exists only in the C object, and the fields are checked on every target.

import { securityTxt } from "std/solana";

securityTxt({
	name: "corpus probe",
	projectUrl: "https://example.org",
	contacts: "email:security@example.org",
	policy: "https://example.org/policy",
});
console.log("security.txt declared");
