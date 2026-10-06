// @stdout: 34 32 32 kept
// note: text that spells a C header import inside a template literal, a string or a block comment is never read as an import; before, the scan found it and stopped at "cannot read C header", and with the header present it inlined declarations into the string.

const tpl = `import { gone } from "./gone.h";
x`;
const single = 'import { gone } from "./gone.h";';
/* import { gone } from "./gone.h"; */
const double = "import { gone } from \"./gone.h\";";
console.log(tpl.length.toString() + " " + single.length.toString() + " " + double.length.toString() + " kept");
