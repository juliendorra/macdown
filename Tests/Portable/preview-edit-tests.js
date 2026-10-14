// Exercise source projection without WebKit or a macOS runner.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const decoder = {value: ''};
Object.defineProperty(decoder, 'innerHTML', {set(value) {
  this.value = value.replace(/&amp;/g, '&').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&#(\d+);/g, (_, n) => String.fromCodePoint(+n));
}});
const context = {
  window: {webkit: {messageHandlers: {previewInteraction: {postMessage() {}}}}},
  document: {createElement: () => decoder, addEventListener() {}},
};
vm.runInNewContext(fs.readFileSync('MacDown/Resources/Extensions/preview-edit.js', 'utf8'), context);
const project = context.window.__macdownPreviewProject;
for (const [source, text] of [
  ['# Title\n\nSome **bold** and *italic* text.', 'Title Some bold and italic text.'],
  ['## Café 😀\n\n[Link](https://example.com/link) link', 'Café 😀 Link link'],
  ['![image](image.svg)\n\nAfter image', 'After image'],
  ['- [x] Done\n- Next\n\n> Quoted', 'Done Next Quoted'],
  ['```javascript\nconst x = "**literal**";\n```', 'const x = "**literal**";'],
  ['Text `a * b` and \\*escaped\\* &amp; &#128512;', 'Text a * b and *escaped* & 😀'],
  ['word_under_score and __bold__', 'word_under_score and bold'],
  ['[outer **bold**](url_(nested)) after', 'outer bold after'],
  ['Title\n=====\n\n---\n\nAfter', 'Title After'],
  ['| Name | Value |\n| --- | --- |\n| A | B |', 'Name Value A B'],
  ['“Quotes” — café…', '"Quotes" --- café...'],
  ['[label][ref]\n\n[ref]: https://example.com', 'label'],
]) assert.equal(project(source), text, source);
console.log('Preview source projection checks passed.');
