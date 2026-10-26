// @stdout: a[-]b-c a[-]b[-]c a$b-c a<a>b-c a<b-c>b-c a$1b-c a$b-c |a-b-c
// @stdout: x(x|y.z)y(x.y|z)z <ab>ab ;aa;bab; 17 $<n>$0q$
// @stdout: 91,233,55357,56832,93,233,91,55357,56832,93,55357,91,56832,93,56832,91,93,
// @stdout: aaaaaa ac $$
const r = "a-b-c";
console.log(r.replace("-", "[$&]") + " " + r.replaceAll("-", "[$&]") + " " + r.replace("-", "$$") + " " + r.replace("-", "<$`>") + " " + r.replace("-", "<$'>") + " " + r.replace("-", "$1") + " " + r.replace("-", "$") + " " + r.replace("", "|"));
console.log("x.y.z".replaceAll(".", "($`|$')") + " " + "ab".replace("", "<$'>") + " " + "ab".replaceAll("", "$`;") + " " + "é😀".replaceAll("", "[$`]").length + " " + "q".replace("q", "$<n>$0$&$") );
const u = "é😀".replaceAll("", "[$']"); let codes = ""; for (let i = 0; i < u.length; i++) codes += u.charCodeAt(i).toString() + ","; console.log(codes);
console.log("aaa".replaceAll("a", "$&$&") + " " + "abc".replace("b", "") + " " + "x".replaceAll("x", "$$$") );
