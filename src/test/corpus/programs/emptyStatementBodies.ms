;
let checks = 0;
let effects = 0;
while (checks++ < 2);
{
	effects += 10;
}
;
let updates = 0;
for (updates = 0; updates < 3; updates += 1);
let doChecks = 0;
do; while (++doChecks < 2);
let visits = 0;
do visits += 1; while (visits < 2);
if (false) effects = 99; else;
class EmptyHolder {
	;
	value = 7;
	;
}
const holder = new EmptyHolder();
console.log(
	`checks=${checks} updates=${updates} do=${doChecks} effects=${effects} value=${holder.value}`
);
console.log(`visits=${visits}`);
if (checks != 3 || updates != 3 || doChecks != 2 || effects != 10 ||
	holder.value != 7 || visits != 2) {
	throw new Error("empty statement consumed its following statement");
}
