// @stdout: base 1 10
// @stdout: local first 5 10
// @stdout: star first 5 10
// @stdout: named first 5 10
// @stdout: named last 5 10
// @stdout: hidden init
// @stdout: shadowed only 5
// @stdout: cycle 1 2 1 2
// @stdout: static star 7 9 5
// @stdout: static named 7 9 5
// @stdout: static export first 7 9 5
// @stdout: static export last 7 9 5
// @stdout: static local first 11 5
// @stdout: static local last 11 5
// @exit: 0

import { dup as base, only } from "./base";
import { dup as localFirst, only as localOnly } from "./localFirst";
import { dup as starFirst, only as starOnly } from "./starFirst";
import { dup as namedFirst, only as namedFirstOnly } from "./namedFirst";
import { dup as namedLast, only as namedLastOnly } from "./namedLast";
import { dup as shadowedOnly } from "./shadowedHub";
import { pv as fromP, qv as throughP } from "./cycleP";
import { pv as throughQ, qv as fromQ } from "./cycleQ";
import { First as StarFirst, Second as StarSecond, create as starCreate } from "./staticStarFirst";
import { First as NamedFirst, Second as NamedSecond, create as namedCreate } from "./staticNamedFirst";
import {
	First as ExportFirst, Second as ExportFirstOther, create as exportFirstCreate,
} from "./staticExportFirst";
import {
	First as ExportLast, Second as ExportLastOther, create as exportLastCreate,
} from "./staticExportLast";
import { Local as LocalFirst, create as localFirstCreate } from "./staticLocalFirst";
import { Local as LocalLast, create as localLastCreate } from "./staticLocalLast";

console.log("base", base, only);
console.log("local first", localFirst, localOnly);
console.log("star first", starFirst, starOnly);
console.log("named first", namedFirst, namedFirstOnly);
console.log("named last", namedLast, namedLastOnly);
console.log("shadowed only", shadowedOnly);
console.log("cycle", fromP, throughP, throughQ, fromQ);
console.log("static star", StarFirst.create().value, StarSecond.create().value, starCreate());
console.log("static named", NamedFirst.create().value, NamedSecond.create().value, namedCreate());
console.log("static export first", ExportFirst.create().value, ExportFirstOther.create().value,
	exportFirstCreate());
console.log("static export last", ExportLast.create().value, ExportLastOther.create().value,
	exportLastCreate());
console.log("static local first", LocalFirst.create().value, localFirstCreate());
console.log("static local last", LocalLast.create().value, localLastCreate());
