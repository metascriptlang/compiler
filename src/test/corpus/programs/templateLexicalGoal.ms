const first = `\`${7}`;
const middle = `a${7}\`b${7}`;
const plus = `+`;
const subscript = `[]=`;
const angles = `<>`;
const slash = `\\`;
const dollar = `\${name}`;
const result = first + "|" + middle + "|" + plus + "|" + subscript + "|" +
	angles + "|" + slash + "|" + dollar;
if (result != "`7|a7`b7|+|[]=|<>|\\|${name}") {
	throw new Error("template lexical goal changed its cooked value");
}
console.log(result);
