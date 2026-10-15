// GUARD-OS solana
// GUARD-CHECK-FAIL redefinition of 'msSecurityTxt'
// A program carries one security.txt: a second declaration, in this module or another, would put two
// blocks in the ELF for a reader to choose between, so the C symbol both declare is a redefinition.
// RED MEANS: two blocks reached one program silently.
import { logU64, securityTxt } from "std/solana";

securityTxt({ name: "a", projectUrl: "b", contacts: "c", policy: "d" });
securityTxt({ name: "a", projectUrl: "b", contacts: "c", policy: "d" });

logU64(1);
