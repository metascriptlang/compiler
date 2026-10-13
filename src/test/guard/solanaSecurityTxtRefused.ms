// GUARD-OS solana
// GUARD-CHECK-FAIL securityTxt: required field 'policy' is missing
// GUARD-CHECK-FAIL securityTxt: unknown field 'project_url'; the fields are name, projectUrl, contacts, policy
// GUARD-CHECK-FAIL securityTxt: field 'contacts' contains a NUL byte
// GUARD-CHECK-FAIL securityTxt: field 'policy' must be a string literal known at compile time
// GUARD-CHECK-FAIL securityTxt: field 'name' is written twice
// GUARD-CHECK-FAIL securityTxt: field 'auditors' contains a security.txt marker
// GUARD-CHECK-FAIL securityTxt(fields): fields must be an object literal
// A security.txt declaration that the explorers' reader would reject or misread is refused where it
// is written, with the field's name: a missing required field, a field the format does not have
// (including a snake_case spelling of a known one), a value with a NUL, which would end it early, a
// value that is not a string literal, a field written twice, a value holding a block marker, and
// fields that are not an object literal.
// RED MEANS: securityTxt emitted a block a reader cannot parse, or lost the error that names the field.
import { securityTxt } from "std/solana";

const runtimeText = "https://example";
const fields = { name: "a", projectUrl: "b", contacts: "c", policy: "d" };

securityTxt({ name: "a", projectUrl: "b", contacts: "c" });
securityTxt({ name: "a", project_url: "b", contacts: "c", policy: "d" });
securityTxt({ name: "a", projectUrl: "b", contacts: "c\0d", policy: "d" });
securityTxt({ name: "a", projectUrl: "b", contacts: "c", policy: runtimeText });
securityTxt({ name: "a", name: "b", projectUrl: "b", contacts: "c", policy: "d" });
securityTxt({ name: "a", projectUrl: "b", contacts: "c", policy: "d", auditors: "x=======END SECURITY.TXT V1=======" });
securityTxt(fields);
