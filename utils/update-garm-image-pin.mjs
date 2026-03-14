import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { execFileSync } from "node:child_process";

const pinFile = "apps/garm/image-source.env";
const deploymentFile = "apps/garm/deployment.yaml";

function fail(message) {
  console.error(message);
  process.exit(1);
}

function parseEnvFile(content) {
  const vars = {};
  for (const line of content.split(/\r?\n/)) {
    if (!line || line.startsWith("#")) {
      continue;
    }
    const idx = line.indexOf("=");
    if (idx === -1) {
      continue;
    }
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    vars[key] = value;
  }
  return vars;
}

function updateOrAdd(content, key, value) {
  const pattern = new RegExp(`^${key}=.*$`, "m");
  if (pattern.test(content)) {
    return content.replace(pattern, `${key}=${value}`);
  }
  return `${content.trimEnd()}\n${key}=${value}\n`;
}

function gitOut(args, options = {}) {
  return execFileSync("git", args, {
    encoding: "utf8",
    ...options,
  }).trim();
}

function gitRun(args, options = {}) {
  execFileSync("git", args, options);
}

const pinContent = fs.readFileSync(pinFile, "utf8");
const vars = parseEnvFile(pinContent);
const commit = vars.GARM_COMMIT;
const imageRepo = vars.GARM_IMAGE_REPO || "gitea.lumpiasty.xyz/lumpiasty/garm-k8s";

if (!commit || !/^[0-9a-f]{40}$/.test(commit)) {
  fail(`Invalid or missing GARM_COMMIT in ${pinFile}`);
}

const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "garm-main-"));
let commitNumber;
try {
  gitRun(["clone", "--filter=blob:none", "https://github.com/cloudbase/garm.git", tmpDir], {
    stdio: "ignore",
  });
  commitNumber = gitOut(["-C", tmpDir, "rev-list", "--count", commit]);
} finally {
  fs.rmSync(tmpDir, { recursive: true, force: true });
}

if (!/^\d+$/.test(commitNumber)) {
  fail(`Unable to resolve commit number for ${commit}`);
}

const image = `${imageRepo}:r${commitNumber}`;

let nextPin = pinContent;
nextPin = updateOrAdd(nextPin, "GARM_COMMIT_NUMBER", commitNumber);
nextPin = updateOrAdd(nextPin, "GARM_IMAGE_REPO", imageRepo);
nextPin = updateOrAdd(nextPin, "GARM_IMAGE", image);
fs.writeFileSync(pinFile, nextPin, "utf8");

const deployment = fs.readFileSync(deploymentFile, "utf8");
const imagePattern = /image:\s*(?:ghcr\.io\/cloudbase\/garm:[^\s]+|gitea\.lumpiasty\.xyz\/(?:Lumpiasty|lumpiasty)\/garm(?:-k8s)?:[^\s]+)/;
if (!imagePattern.test(deployment)) {
  fail(`Unable to update garm image in ${deploymentFile}`);
}

const updatedDeployment = deployment.replace(imagePattern, `image: ${image}`);

fs.writeFileSync(deploymentFile, updatedDeployment, "utf8");
console.log(`Pinned garm image to ${image}`);
