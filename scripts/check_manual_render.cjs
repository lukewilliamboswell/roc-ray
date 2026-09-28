#!/usr/bin/env node
// Renders the built manual in headless Chromium and checks what a reader sees.
// scripts/build_manual.py runs this inside the documentation container, where
// Puppeteer ships with Mermaid's CLI; it is not meant to be run on its own.
//
//   node scripts/check_manual_render.cjs .docs-out/site/index.html
//
// Checks, in the light and the dark scheme:
//   - no Rouge token inside a code block paints its own background (the
//     dark-mode "white boxes" bug);
//   - every visible run of text meets WCAG AA contrast against the ground it
//     sits on (4.5:1, or 3:1 for large text);
// and at phone and tablet widths:
//   - the page never scrolls sideways (wide tables and code scroll in their
//     own box);
//   - the manual's text starts on the first screen, not after the contents;
// and that the page requests nothing from another host.

"use strict";

const path = require("path");
const puppeteer = require("puppeteer");

const page_path = process.argv[2];
if (!page_path) {
  console.error("usage: check_manual_render.cjs PAGE");
  process.exit(2);
}
const url = "file://" + path.resolve(page_path);

async function main() {
  const browser = await puppeteer.launch({
    headless: true,
    args: ["--no-sandbox", "--disable-crashpad", "--disable-crash-reporter"],
  });
  const failures = [];
  try {
    const page = await browser.newPage();
    const remote = [];
    page.on("request", (request) => {
      if (/^https?:/.test(request.url())) remote.push(request.url());
    });

    for (const scheme of ["light", "dark"]) {
      await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: scheme }]);
      await page.setViewport({ width: 1440, height: 900 });
      await page.goto(url, { waitUntil: "load" });
      await page.evaluate(() => document.fonts.ready);
      const result = await page.evaluate(inspectScheme);
      for (const problem of result) failures.push(`${scheme}: ${problem}`);
    }

    for (const [width, height] of [[390, 844], [768, 1024]]) {
      await page.emulateMediaFeatures([{ name: "prefers-color-scheme", value: "light" }]);
      await page.setViewport({ width, height, isMobile: true, hasTouch: true, deviceScaleFactor: 1 });
      await page.goto(url, { waitUntil: "load" });
      await page.evaluate(() => document.fonts.ready);
      const result = await page.evaluate(inspectNarrow, width, height);
      for (const problem of result) failures.push(`${width}px: ${problem}`);
    }

    for (const request of new Set(remote)) failures.push(`requests a third-party resource: ${request}`);
  } finally {
    await browser.close();
  }

  if (failures.length) {
    console.error("The rendered manual has problems:\n  " + failures.join("\n  "));
    process.exit(1);
  }
  console.log("Rendering checks passed (light and dark; 390px, 768px and 1440px).");
}

// ---------------------------------------------------------------- in page

function inspectScheme() {
  const problems = [];

  function parse(color) {
    const m = color.match(/rgba?\(([^)]+)\)/);
    if (!m) return null;
    const parts = m[1].split(/[ ,/]+/).filter(Boolean).map(Number);
    return { r: parts[0], g: parts[1], b: parts[2], a: parts.length > 3 ? parts[3] : 1 };
  }
  function over(top, bottom) {
    const a = top.a;
    return {
      r: top.r * a + bottom.r * (1 - a),
      g: top.g * a + bottom.g * (1 - a),
      b: top.b * a + bottom.b * (1 - a),
      a: 1,
    };
  }
  function luminance(c) {
    const f = (v) => {
      v /= 255;
      return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
    };
    return 0.2126 * f(c.r) + 0.7152 * f(c.g) + 0.0722 * f(c.b);
  }
  function ratio(a, b) {
    const x = luminance(a);
    const y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }
  const ground = new Map();
  function background(element) {
    if (!element) return parse(getComputedStyle(document.body).backgroundColor) || { r: 255, g: 255, b: 255, a: 1 };
    if (ground.has(element)) return ground.get(element);
    const own = parse(getComputedStyle(element).backgroundColor);
    const below = element === document.documentElement ? { r: 255, g: 255, b: 255, a: 1 } : background(element.parentElement);
    const result = own && own.a > 0 ? over(own, below) : below;
    ground.set(element, result);
    return result;
  }

  // Rouge tokens take the block's ground.
  const painted = new Set();
  for (const token of document.querySelectorAll("pre.rouge span:not(.hll)")) {
    const bg = parse(getComputedStyle(token).backgroundColor);
    if (bg && bg.a > 0) painted.add(`.${token.className} (${getComputedStyle(token).backgroundColor})`);
  }
  for (const token of painted) problems.push(`Rouge token ${token} has its own background inside a code block`);

  // Contrast of every visible text run.
  const low = new Map();
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.nodeValue.trim()) continue;
    const element = node.parentElement;
    if (!element || element.closest("script, style, .imageblock, [hidden]")) continue;
    const style = getComputedStyle(element);
    if (style.visibility === "hidden" || style.display === "none" || !element.getClientRects().length) continue;
    const color = parse(style.color);
    if (!color) continue;
    const bg = background(element);
    const fg = color.a < 1 ? over(color, bg) : color;
    const size = parseFloat(style.fontSize);
    const bold = Number(style.fontWeight) >= 700;
    const large = size >= 24 || (bold && size >= 18.66);
    const needed = large ? 3 : 4.5;
    const got = ratio(fg, bg);
    if (got + 1e-6 < needed) {
      const key = `${element.tagName.toLowerCase()}${element.className ? "." + String(element.className).trim().split(/\s+/).join(".") : ""} ${style.color} on rgb(${Math.round(bg.r)}, ${Math.round(bg.g)}, ${Math.round(bg.b)}) = ${got.toFixed(2)}:1 (needs ${needed}:1)`;
      if (!low.has(key)) low.set(key, node.nodeValue.trim().slice(0, 40));
    }
  }
  for (const [key, sample] of low) problems.push(`low contrast: ${key}, e.g. ${JSON.stringify(sample)}`);
  return problems;
}

// A mobile viewport widens its layout viewport to fit overflowing content, so
// compare against the device width rather than window.innerWidth.
function inspectNarrow(width, height) {
  const problems = [];
  const root = document.documentElement;
  if (root.scrollWidth > width + 1) {
    const culprits = [];
    for (const element of document.querySelectorAll("#content *, #toc *, #header *")) {
      const box = element.getBoundingClientRect();
      if (box.right > width + 1 && element.parentElement.getBoundingClientRect().right <= width + 1) {
        const section = element.closest(".sect4, .sect3, .sect2, .sect1");
        const heading = section && section.querySelector(":scope > [id]");
        culprits.push(`${element.tagName.toLowerCase()} in #${heading ? heading.id : "?"}`);
      }
    }
    problems.push(
      `the page scrolls sideways (${root.scrollWidth}px wide on a ${width}px screen): ` +
        culprits.slice(0, 8).join(", "),
    );
  }
  const content = document.getElementById("content");
  const top = content.getBoundingClientRect().top + window.scrollY;
  if (top > height) {
    problems.push(`the manual's text starts ${Math.round(top)}px down, below the first ${height}px screen`);
  }
  const toggle = document.getElementById("toc-toggle");
  if (!toggle || !toggle.getClientRects().length) problems.push("the contents bar is missing");
  return problems;
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
