(async () => {
  const root = await navigator.storage.getDirectory();
  const files = [];
  const texts = {};
  const enc = new TextDecoder();
  async function hash(buf) {
    const d = await crypto.subtle.digest('SHA-256', buf);
    return Array.from(new Uint8Array(d)).map((b) => b.toString(16).padStart(2, '0')).join('');
  }
  async function walk(dir, path) {
    const entries = [];
    for await (const [name, handle] of dir.entries()) entries.push([name, handle]);
    entries.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    for (const [name, handle] of entries) {
      const p = path + '/' + name;
      if (handle.kind === 'directory') { await walk(handle, p); continue; }
      const f = await handle.getFile();
      const buf = await f.arrayBuffer();
      files.push({ path: p, size: buf.byteLength, sha256: await hash(buf) });
      if (name.endsWith('.json') && buf.byteLength < 4000000) texts[p] = enc.decode(buf);
    }
  }
  await walk(root, '');
  return JSON.stringify({ files, texts });
})()
