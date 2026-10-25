// @selftest-red unknown directive '// @max-rss: 64'
// @stdout: ok
// @max-rss: 64
// A misspelt directive must be red: the runner would ignore it and the program would assert less than it says.

console.log("ok");
