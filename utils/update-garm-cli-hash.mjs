import { createHash } from "node:crypto";
import { Buffer } from "node:buffer";
import fs from "node:fs";
import https from "node:https";
import zlib from "node:zlib";

const nixFile = "nix/garm-cli.nix";

function die(message) {
  console.error(message);
  process.exit(1);
}

function readText(filePath) {
  try {
    return fs.readFileSync(filePath, "utf8");
  } catch {
    die(`Missing ${filePath}`);
  }
}

function extractVersion(text) {
  const match = text.match(/^\s*version\s*=\s*"([^"]+)";/m);
  if (!match) {
    die(`Unable to extract version from ${nixFile}`);
  }
  return match[1];
}

function extractCommit(text) {
  const match = text.match(/^\s*garmCommit\s*=\s*"([a-f0-9]{40})";/m);
  return match ? match[1] : null;
}

function writeU64LE(hash, value) {
  const buf = Buffer.alloc(8);
  buf.writeBigUInt64LE(BigInt(value), 0);
  hash.update(buf);
}

function writeNarString(hash, data) {
  writeU64LE(hash, data.length);
  hash.update(data);
  const pad = (8 - (data.length % 8)) % 8;
  if (pad) {
    hash.update(Buffer.alloc(pad));
  }
}

function writeNarText(hash, text) {
  writeNarString(hash, Buffer.from(text, "utf8"));
}

function parseOctal(field) {
  const clean = field.toString("ascii").replace(/\0.*$/, "").trim();
  if (!clean) {
    return 0;
  }
  return Number.parseInt(clean, 8);
}

function parseTarHeader(block) {
  const name = block.subarray(0, 100).toString("utf8").replace(/\0.*$/, "");
  const mode = parseOctal(block.subarray(100, 108));
  const size = parseOctal(block.subarray(124, 136));
  const typeflagRaw = block[156];
  const typeflag = typeflagRaw === 0 ? "0" : String.fromCharCode(typeflagRaw);
  const linkname = block.subarray(157, 257).toString("utf8").replace(/\0.*$/, "");
  const prefix = block.subarray(345, 500).toString("utf8").replace(/\0.*$/, "");
  return {
    name: prefix ? `${prefix}/${name}` : name,
    mode,
    size,
    typeflag,
    linkname,
  };
}

function parsePax(data) {
  const out = {};
  let i = 0;
  while (i < data.length) {
    let sp = i;
    while (sp < data.length && data[sp] !== 0x20) sp += 1;
    if (sp >= data.length) break;
    const len = Number.parseInt(data.subarray(i, sp).toString("utf8"), 10);
    if (!Number.isFinite(len) || len <= 0) break;
    const record = data.subarray(sp + 1, i + len).toString("utf8");
    const eq = record.indexOf("=");
    if (eq > 0) {
      const key = record.slice(0, eq);
      const value = record.slice(eq + 1).replace(/\n$/, "");
      out[key] = value;
    }
    i += len;
  }
  return out;
}

function parseTarEntries(archiveBuffer) {
  const gz = zlib.gunzipSync(archiveBuffer);
  const entries = [];
  let i = 0;
  let pendingPax = null;
  let longName = null;
  let longLink = null;

  while (i + 512 <= gz.length) {
    const header = gz.subarray(i, i + 512);
    i += 512;

    if (header.every((b) => b === 0)) {
      break;
    }

    const h = parseTarHeader(header);
    const data = gz.subarray(i, i + h.size);
    const dataPad = (512 - (h.size % 512)) % 512;
    i += h.size + dataPad;

    if (h.typeflag === "x") {
      pendingPax = parsePax(data);
      continue;
    }
    if (h.typeflag === "g") {
      continue;
    }
    if (h.typeflag === "L") {
      longName = data.toString("utf8").replace(/\0.*$/, "");
      continue;
    }
    if (h.typeflag === "K") {
      longLink = data.toString("utf8").replace(/\0.*$/, "");
      continue;
    }

    const path = pendingPax?.path ?? longName ?? h.name;
    const linkpath = pendingPax?.linkpath ?? longLink ?? h.linkname;

    entries.push({
      path,
      typeflag: h.typeflag,
      mode: h.mode,
      linkname: linkpath,
      data,
    });

    pendingPax = null;
    longName = null;
    longLink = null;
  }

  return entries;
}

function stripTopDir(path) {
  const cleaned = path.replace(/^\.?\//, "").replace(/\/$/, "");
  const idx = cleaned.indexOf("/");
  if (idx === -1) return "";
  return cleaned.slice(idx + 1);
}

function ensureDir(root, relPath) {
  if (!relPath) return root;
  const parts = relPath.split("/").filter(Boolean);
  let cur = root;
  for (const part of parts) {
    let child = cur.children.get(part);
    if (!child) {
      child = { kind: "directory", children: new Map() };
      cur.children.set(part, child);
    }
    if (child.kind !== "directory") {
      die(`Path conflict while building tree at ${relPath}`);
    }
    cur = child;
  }
  return cur;
}

function buildTree(entries) {
  const root = { kind: "directory", children: new Map() };
  for (const entry of entries) {
    const rel = stripTopDir(entry.path);
    if (!rel) {
      continue;
    }

    const parts = rel.split("/").filter(Boolean);
    const name = parts.pop();
    const parent = ensureDir(root, parts.join("/"));

    if (entry.typeflag === "5") {
      const existing = parent.children.get(name);
      if (!existing) {
        parent.children.set(name, { kind: "directory", children: new Map() });
      } else if (existing.kind !== "directory") {
        die(`Path conflict at ${rel}`);
      }
      continue;
    }

    if (entry.typeflag === "2") {
      parent.children.set(name, { kind: "symlink", target: entry.linkname });
      continue;
    }

    if (entry.typeflag === "0") {
      parent.children.set(name, {
        kind: "regular",
        executable: (entry.mode & 0o111) !== 0,
        contents: Buffer.from(entry.data),
      });
      continue;
    }
  }
  return root;
}

function compareUtf8(a, b) {
  return Buffer.from(a, "utf8").compare(Buffer.from(b, "utf8"));
}

function narDump(hash, node) {
  if (node.kind === "directory") {
    writeNarText(hash, "(");
    writeNarText(hash, "type");
    writeNarText(hash, "directory");
    const names = [...node.children.keys()].sort(compareUtf8);
    for (const name of names) {
      writeNarText(hash, "entry");
      writeNarText(hash, "(");
      writeNarText(hash, "name");
      writeNarString(hash, Buffer.from(name, "utf8"));
      writeNarText(hash, "node");
      narDump(hash, node.children.get(name));
      writeNarText(hash, ")");
    }
    writeNarText(hash, ")");
    return;
  }

  if (node.kind === "symlink") {
    writeNarText(hash, "(");
    writeNarText(hash, "type");
    writeNarText(hash, "symlink");
    writeNarText(hash, "target");
    writeNarString(hash, Buffer.from(node.target, "utf8"));
    writeNarText(hash, ")");
    return;
  }

  writeNarText(hash, "(");
  writeNarText(hash, "type");
  writeNarText(hash, "regular");
  if (node.executable) {
    writeNarText(hash, "executable");
    writeNarText(hash, "");
  }
  writeNarText(hash, "contents");
  writeNarString(hash, node.contents);
  writeNarText(hash, ")");
}

function fetchBuffer(url) {
  return new Promise((resolve, reject) => {
    https
      .get(url, (res) => {
        if (res.statusCode && res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
          const redirectUrl = new URL(res.headers.location, url).toString();
          res.resume();
          fetchBuffer(redirectUrl).then(resolve, reject);
          return;
        }
        if (!res.statusCode || res.statusCode < 200 || res.statusCode >= 300) {
          reject(new Error(`Failed to fetch ${url}: ${res.statusCode ?? "unknown"}`));
          res.resume();
          return;
        }
        const chunks = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => resolve(Buffer.concat(chunks)));
      })
      .on("error", reject);
  });
}

function computeSRIFromGitHubTar(ref) {
  const url = `https://github.com/cloudbase/garm/archive/${ref}.tar.gz`;
  return fetchBuffer(url).then((archive) => {
      const entries = parseTarEntries(archive);
      const root = buildTree(entries);
      const hash = createHash("sha256");
      writeNarText(hash, "nix-archive-1");
      narDump(hash, root);
      return `sha256-${hash.digest("base64")}`;
    });
}

function updateHash(text, sri) {
  const pattern = /(^\s*hash\s*=\s*")sha256-[^"]+(";)/m;
  if (!pattern.test(text)) {
    die(`Unable to update hash in ${nixFile}`);
  }
  const next = text.replace(pattern, `$1${sri}$2`);
  return next;
}

async function main() {
  const text = readText(nixFile);
  const version = extractVersion(text);
  const commit = extractCommit(text);
  const ref = commit ?? `v${version}`;
  const sri = await computeSRIFromGitHubTar(ref);
  const updated = updateHash(text, sri);
  fs.writeFileSync(nixFile, updated, "utf8");
  console.log(`Updated ${nixFile} hash to ${sri}`);
}

main().catch((err) => die(err.message));
