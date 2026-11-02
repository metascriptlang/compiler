// @stdout: a directory on PATH is not a program
// @skip-js: std/process has no findOnPath on JS; node resolves its own PATH
import { findOnPath, env, platform, cwd } from "std/process";
import { mkdir, writeFile, chmod, removeAll } from "std/fs";

const name = platform == "windows" ? "msOnPathProbe.exe" : "msOnPathProbe";
const root = `${cwd()}/out/msOnPathProbe`;
removeAll(root);
const shadow = `${root}/shadow`;
const real = `${root}/real`;
mkdir(`${cwd()}/out`);
mkdir(root);
mkdir(shadow);
mkdir(`${shadow}/${name}`);
mkdir(real);
writeFile(`${real}/${name}`, "#!/bin/sh\n");
chmod(`${real}/${name}`, 0o755);

const separator = platform == "windows" ? ";" : ":";
const saved = env.get("PATH");
env.set("PATH", `${shadow}${separator}${real}`);
const skipsToFile = findOnPath(name) == `${real}/${name}`;
env.set("PATH", shadow);
const onlyDirectory = findOnPath(name) == "";
env.set("PATH", saved);
const directPath = findOnPath(`${shadow}/${name}`) == "";
removeAll(root);

console.log(skipsToFile && onlyDirectory && directPath
	? "a directory on PATH is not a program"
	: `skipsToFile ${skipsToFile} onlyDirectory ${onlyDirectory} directPath ${directPath}`);
