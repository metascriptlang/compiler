// @stdout: 3 4 5 6 7
interface Box<T> { value: T; }
function apply<T>(make: () => T): T { return make(); }

const two = (): Box<Box<int32>> => ({ value: { value: 3 } });
const three = (): Box<Box<Box<int32>>> => ({ value: { value: { value: 4 } } });
const passed = apply((): Box<Box<int32>> => ({ value: { value: 5 } }));
function declared(): Box<Box<int32>> { return { value: { value: 6 } }; }
const annotated: Box<Box<int32>> = { value: { value: 7 } };
console.log(`${two().value.value} ${three().value.value.value} ${passed.value.value} ${declared().value.value} ${annotated.value.value}`);
