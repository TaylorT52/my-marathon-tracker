import {mkdir, readFile, writeFile} from "node:fs/promises";
import {resolve} from "node:path";

const output = resolve("dist");
const client = resolve(output, "client");
let html = await readFile(resolve(client, "index.html"), "utf8");

const stylesheet = html.match(/<link rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/);
if (stylesheet) {
  const css = await readFile(resolve(client, stylesheet[1].replace(/^\//, "")), "utf8");
  html = html.replace(stylesheet[0], `<style>${css}</style>`);
}

const script = html.match(/<script type="module"[^>]*src="([^"]+)"[^>]*><\/script>/);
if (script) {
  const javascript = await readFile(
    resolve(client, script[1].replace(/^\//, "")),
    "utf8",
  );
  html = html.replace(
    script[0],
    `<script type="module">${javascript.replaceAll("</script", "<\\/script")}</script>`,
  );
}

const worker = `
const html = ${JSON.stringify(html)};
export default {
  async fetch(request) {
    const url = new URL(request.url);
    if (url.pathname !== "/") {
      return new Response("Not found", {status: 404});
    }
    return new Response(html, {
      headers: {
        "content-type": "text/html; charset=utf-8",
        "cache-control": "public, max-age=60",
        "x-content-type-options": "nosniff"
      }
    });
  }
};
`;

await mkdir(resolve(output, "server"), {recursive: true});
await writeFile(resolve(output, "server", "index.js"), worker);
