// Runs in WKContentWorld.defaultClientWorld. Document scripts cannot call the
// mutation bridge. Source offsets use UTF-16, the same units as NSTextView.
(() => {
  'use strict';
  const bridge = window.webkit.messageHandlers.previewInteraction;
  let state = null, mapping = null, composing = null, selectionPending = false, softBreak = false, deferred = false;
  let active = false, fastCaret = null;
  const generated = 'script,style,.toc,.footnotes,.footnote-ref,.line-numbers-rows,.toolbar,[data-macdown-notice]';
  const blocks = /^(P|H[1-6]|LI|TD|TH|PRE|BLOCKQUOTE|UL|OL|TABLE|TR|DIV)$/;
  const decoder = document.createElement('textarea');
  const make = () => ({text: '', starts: [], ends: []});
  function put(out, text, start, end) {
    out.text += text;
    for (let k = 0; k < text.length; k++) { out.starts.push(start); out.ends.push(end); }
  }
  function literal(out, source, start, end) {
    out.text += source.slice(start, end);
    for (let k = start; k < end; k++) { out.starts.push(k); out.ends.push(k + 1); }
  }
  function closing(source, start, open, close, end) {
    let depth = 1;
    for (let i = start; i < end; i++) {
      if (source[i] === '\\') { i++; continue; }
      if (source[i] === open) depth++;
      else if (source[i] === close && !--depth) return i;
    }
    return -1;
  }
  function inline(out, source, start, end, depth = 0) {
    if (depth > 32) return; // Match the renderer's bounded nesting policy.
    for (let i = start; i < end;) {
      const tail = source.slice(i, end);
      let match;
      if (source[i] === '\\' && /[!"#$%&'()*+,\-./:;<=>?@[\]\\^_`{|}~]/.test(source[i + 1] || '')) {
        put(out, source[i + 1], i, i + 2); i += 2; continue;
      }
      if ((match = tail.match(/^&(?:#\d+|#x[\da-f]+|[a-z][\da-z]+);/i))) {
        decoder.innerHTML = match[0]; put(out, decoder.value, i, i + match[0].length);
        i += match[0].length; continue;
      }
      if ((match = tail.match(/^`+/))) {
        const delimiter = match[0];
        let close = source.indexOf(delimiter, i + delimiter.length);
        while (close >= 0 && close < end && (source[close - 1] === '`' || source[close + delimiter.length] === '`'))
          close = source.indexOf(delimiter, close + delimiter.length);
        if (close >= 0 && close < end) {
          let a = i + delimiter.length, b = close;
          if (source[a] === ' ' && source[b - 1] === ' ' && /[^ ]/.test(source.slice(a, b))) { a++; b--; }
          for (let j = a; j < b; j++) put(out, /[\r\n]/.test(source[j]) ? ' ' : source[j], j, j + 1);
          i = close + delimiter.length; continue;
        }
      }
      const image = source[i] === '!' && source[i + 1] === '[';
      if (image || source[i] === '[') {
        const opening = i + (image ? 1 : 0);
        const close = closing(source, opening + 1, '[', ']', end);
        if (close >= 0) {
          let after = close + 1;
          if (source[after] === '(') {
            const destination = closing(source, after + 1, '(', ')', end);
            if (destination >= 0) after = destination + 1;
          } else if (source[after] === '[') {
            const reference = source.indexOf(']', after + 1);
            if (reference >= 0 && reference < end) after = reference + 1;
          }
          if (after > close + 1) {
            if (!image) inline(out, source, opening + 1, close, depth + 1);
            i = after; continue;
          }
        }
      }
      if ((match = tail.match(/^<(?:https?:\/\/|mailto:)[^<>\s]+>/i))) {
        const skip = match[0].startsWith('<mailto:') ? 8 : 1;
        literal(out, source, i + skip, i + match[0].length - 1); i += match[0].length; continue;
      }
      if ((match = tail.match(/^(\*{1,3}|_{1,3}|~~|==)/))) {
        const delimiter = match[0];
        const inWord = delimiter[0] === '_' && /[\p{L}\p{N}]/u.test(source[i - 1] || '') && /[\p{L}\p{N}]/u.test(source[i + delimiter.length] || '');
        const close = source.indexOf(delimiter, i + delimiter.length);
        if (!inWord && close > i + delimiter.length && close < end && !/^\s|\s$/.test(source.slice(i + delimiter.length, close))) {
          inline(out, source, i + delimiter.length, close, depth + 1); i = close + delimiter.length; continue;
        }
      }
      literal(out, source, i, i + 1); i++;
    }
  }
  function project(source, offset = 0, toc = false) {
    const out = make(); let fence = null, rawHTML = false;
    const lines = Array.from(source.slice(offset).matchAll(/[^\r\n]*(?:\r\n|\r|\n|$)/g));
    for (let l = 0; l < lines.length; l++) {
      const line = lines[l][0]; if (!line) continue;
      const base = offset + lines[l].index;
      let text = line.replace(/[\r\n]+$/, ''), start = base;
      if (fence) {
        if (new RegExp('^ {0,3}' + fence[0] + '{' + fence.length + ',}\\s*$').test(text)) fence = null;
        else literal(out, source, start, start + text.length);
        put(out, '\n', base + text.length, base + line.length); continue;
      }
      // Container prefixes carry no rendered text. Keep original source offsets.
      const prefix = text.match(/^\s*(?:(?:>\s*)+|(?:[-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?)/);
      if (prefix) { start += prefix[0].length; text = text.slice(prefix[0].length); }
      const fenced = text.match(/^ {0,3}(`{3,}|~{3,})/);
      if (fenced) { fence = fenced[1]; put(out, '\n', base, base + line.length); continue; }
      if (!text.trim()) { rawHTML = false; put(out, '\n', base, base + line.length); continue; }
      // Arbitrary HTML/generated content is intentionally unmapped. Unique
      // unaffected blocks can still be mapped below, without guessing offsets.
      if (/^ {0,3}<(?:[a-z!/]|\?)/i.test(text) && !/^\s*<(?:https?:\/\/|mailto:)/i.test(text)) rawHTML = true;
      if (rawHTML || /^ {0,3}\[[^\]]+\]:/.test(text) || (toc && /^\s*\[TOC\]\s*$/i.test(text)) ||
          /^ {0,3}(?:(?:\*\s*){3,}|(?:-\s*){3,}|(?:_\s*){3,})$/.test(text) ||
          (l && /^ {0,3}(?:=+|-+)\s*$/.test(text)) || /^\s*\|?\s*:?-{3,}:?\s*(?:\|\s*:?-{3,}:?\s*)+\|?\s*$/.test(text)) {
        put(out, '\n', base, base + line.length); continue;
      }
      const heading = text.match(/^ {0,3}#{1,6}\s+/);
      if (heading) { start += heading[0].length; text = text.slice(heading[0].length).replace(/\s+#+\s*$/, ''); }
      const table = text.includes('|') && (l && /\|/.test(lines[l - 1][0]) || lines[l + 1] && /\|.*-/.test(lines[l + 1][0]));
      if (table) {
        let cellStart = 0;
        for (let j = 0; j <= text.length; j++) if (j === text.length || text[j] === '|' && text[j - 1] !== '\\') {
          inline(out, source, start + cellStart, start + j); put(out, ' ', start + j, start + j + 1); cellStart = j + 1;
        }
      } else inline(out, source, start, start + text.length);
      put(out, '\n', base + line.replace(/[\r\n]+$/, '').length, base + line.length);
    }
    return out;
  }
  function canonical(input) {
    const out = make();
    const alternatives = {'‘': "'", '’': "'", '“': '"', '”': '"', '…': '...', '–': '--', '—': '---'};
    for (let i = 0; i < input.text.length; i++) {
      const char = input.text[i], start = input.starts[i], end = input.ends[i];
      if (/\s/.test(char)) {
        if (!out.text.length) continue;
        if (out.text.endsWith(' ')) { out.ends[out.ends.length - 1] = end; continue; }
        put(out, ' ', start, end);
      } else put(out, alternatives[char] || char, start, end);
    }
    if (out.text.endsWith(' ')) { out.text = out.text.slice(0, -1); out.starts.pop(); out.ends.pop(); }
    return out;
  }
  function collect(root = document.body) {
    const out = make(), records = [], byNode = new WeakMap(), byElement = new WeakMap();
    function visit(node) {
      if (node.nodeType === Node.TEXT_NODE) {
        const record = {node, base: out.text.length, length: node.length, text: node.data}; records.push(record); byNode.set(node, record);
        literal(out, node.data, 0, node.length);
        // DOM offsets live in the flattened text, including block separators.
        for (let k = record.base; k < out.text.length; k++) { out.starts[k] = k; out.ends[k] = k + 1; }
      } else if (node.nodeType === Node.ELEMENT_NODE && !node.matches(generated)) {
        const first = records.length;
        const block = blocks.test(node.tagName) || node.tagName === 'BR';
        if (block) put(out, '\n', out.text.length, out.text.length + 1);
        node.childNodes.forEach(visit);
        if (records.length > first) byElement.set(node, {first: records[first], last: records[records.length - 1]});
        if (block) put(out, '\n', out.text.length, out.text.length + 1);
      }
    }
    visit(root); return {out, records, byNode, byElement};
  }
  function buildMap(scope = null) {
    if (!state) { mapping = null; return; }
    const projected = scope ? project(scope.source) : project(state.source, state.offset, state.toc);
    if (scope) {
      for (let i = 0; i < projected.starts.length; i++) { projected.starts[i] += scope.offset; projected.ends[i] += scope.offset; }
    }
    const source = canonical(projected);
    const dom = collect(scope ? scope.root : document.body), rendered = canonical(dom.out);
    if (scope && source.text !== rendered.text) return false;
    const starts = new Int32Array(dom.out.text.length).fill(-1), ends = new Int32Array(starts.length).fill(-1);
    function assign(from, to, sourceIndex) {
      for (let i = from; i < to; i++) {
        const s = source.starts[sourceIndex + i - from], e = source.ends[sourceIndex + i - from];
        for (let j = rendered.starts[i]; j < rendered.ends[i]; j++) { starts[j] = s; ends[j] = e; }
      }
    }
    if (source.text === rendered.text) assign(0, rendered.text.length, 0);
    else {
      // Fail closed for unsupported constructs. A block is usable only if its
      // entire rendered text has one exact occurrence in the projected source.
      const lowerBound = (values, target) => {
        let a = 0, b = values.length;
        while (a < b) { const middle = (a + b) >>> 1; if (values[middle] < target) a = middle + 1; else b = middle; }
        return a;
      };
      for (const element of document.querySelectorAll('p,h1,h2,h3,h4,h5,h6,li,td,th,pre')) {
        if (element.closest(generated)) continue;
        const records = dom.byElement.get(element); if (!records) continue;
        const a = records.first.base, b = records.last.base + records.last.length;
        let first = lowerBound(rendered.starts, a), last = first;
        while (last < rendered.text.length && rendered.ends[last] <= b) last++;
        const text = rendered.text.slice(first, last).trim(); if (!text) continue;
        const index = source.text.indexOf(text);
        if (index < 0 || source.text.indexOf(text, index + 1) >= 0 ||
            index > 0 && !/\s/.test(source.text[index - 1]) ||
            index + text.length < source.text.length && !/\s/.test(source.text[index + text.length])) continue;
        while (rendered.text[first] === ' ') first++;
        assign(first, first + text.length, index);
      }
    }
    // HTML paragraphs collapse whitespace, but code editing must retain each
    // indentation character. Recover code whitespace from adjacent exact text
    // anchors instead of assigning a collapsed run to every individual space.
    const codeElements = Array.from((scope ? scope.root : document.body).querySelectorAll('code'));
    if (scope && scope.root.matches('code')) codeElements.push(scope.root);
    for (const code of codeElements) {
      const records = dom.byElement.get(code); if (!records) continue;
      const a = records.first.base, b = records.last.base + records.last.length;
      let previous = -1;
      const following = new Int32Array(b - a).fill(-1); let next = -1;
      for (let j = b - 1; j >= a; j--) { following[j - a] = next; if (!/\s/.test(dom.out.text[j]) && starts[j] >= 0) next = j; }
      for (let j = a; j < b; j++) {
        if (!/\s/.test(dom.out.text[j])) { if (starts[j] >= 0) previous = j; continue; }
        const next = following[j - a];
        const forward = previous < 0 ? -1 : ends[previous] + j - previous - 1;
        const backward = next < 0 ? -1 : starts[next] - (next - j);
        const position = forward >= 0 && state.source[forward] === dom.out.text[j] ? forward
          : backward >= 0 && state.source[backward] === dom.out.text[j] ? backward : -1;
        starts[j] = position; ends[j] = position < 0 ? -1 : position + 1;
      }
    }
    mapping = {starts, ends, records: dom.records, byNode: dom.byNode, partial: !!scope};
    return true;
  }
  function enableEditing() {
    document.body.contentEditable = 'plaintext-only';
    document.body.setAttribute('aria-label', 'Markdown preview. Edit text directly; selections are linked to the Markdown editor.');
    document.body.style.caretColor = 'auto';
    document.body.style.outline = 'none';
  }
  function point(node, offset, end) {
    if (!mapping || !document.body.contains(node)) return null;
    for (let element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement; element; element = element.parentElement)
      if (mapping.emptyHosts?.has(element)) return mapping.emptyHosts.get(element);
    if (node.nodeType !== Node.TEXT_NODE) {
      const child = node.childNodes[offset];
      const candidates = mapping.records.filter(r => child ? child === r.node || child.contains(r.node) : node.contains(r.node));
      if (!candidates.length) return null;
      const record = child ? candidates[0] : candidates[candidates.length - 1];
      node = record.node; offset = child ? 0 : record.length;
    }
    const record = mapping.byNode.get(node); if (!record) return null;
    if (record.emptyOffset !== undefined) return record.emptyOffset;
    if (node.data !== record.text) return null; // A document script changed this node.
    if (record.caretOffset !== undefined && offset === record.length) return record.caretOffset;
    if (end && offset > 0) { const value = mapping.ends[record.base + offset - 1]; return value < 0 ? null : value; }
    if (offset < record.length) { const value = mapping.starts[record.base + offset]; return value < 0 ? null : value; }
    if (offset > 0) { const value = mapping.ends[record.base + offset - 1]; return value < 0 ? null : value; }
    return null;
  }
  function selected() {
    const selection = getSelection(); if (!state || !selection.rangeCount) return null;
    active = true;
    const range = selection.getRangeAt(0);
    if (fastCaret && range.collapsed && document.body.contains(fastCaret.node) &&
        fastCaret.node.data === fastCaret.text && (range.startContainer === fastCaret.node && range.startOffset === fastCaret.node.length ||
            fastCaret.host && !fastCaret.host.textContent && fastCaret.host.contains(range.startContainer)))
      return {start: fastCaret.offset, end: fastCaret.offset, range, text: ''};
    if (!mapping) buildMap();
    let start = point(range.startContainer, range.startOffset, false);
    let end = range.collapsed ? start : point(range.endContainer, range.endOffset, true);
    if ((start === null || end === null) && mapping.partial) {
      buildMap(); start = point(range.startContainer, range.startOffset, false);
      end = range.collapsed ? start : point(range.endContainer, range.endOffset, true);
    }
    if (start === null || end === null || end < start) return null;
    return {start, end, range, text: selection.toString()};
  }
  function post(kind, values = {}) {
    if (state) bridge.postMessage({kind, token: state.token, sequence: state.sequence, ...values});
  }
  let noticeTimer;
  function notice(text) {
    let node = document.querySelector('[data-macdown-notice]');
    if (!node) {
      node = document.createElement('div'); node.dataset.macdownNotice = ''; node.contentEditable = 'false';
      node.setAttribute('role', 'status'); node.style.cssText = 'position:fixed;bottom:16px;left:16px;right:16px;padding:10px 14px;background:#222;color:white;border-radius:8px;font:13px -apple-system;z-index:2147483647;pointer-events:none;';
      document.body.appendChild(node);
    }
    node.textContent = text; clearTimeout(noticeTimer); noticeTimer = setTimeout(() => node.remove(), 3500);
  }
  function escapeText(text, code) {
    if (code) return text;
    return text.replace(/&/g, '&amp;').replace(/[\\`*_\[\]<>~^=!|#]/g, '\\$&');
  }
  function breakFormatting(selection, newline) {
    if (!selection) return {selection, newline};
    if (!mapping) buildMap();
    const delimiters = [], source = state.source;
    let element = selection.range.startContainer.parentElement;
    for (; element && !blocks.test(element.tagName); element = element.parentElement) {
      const choices = {STRONG: ['**','__'], EM: ['*','_'], DEL: ['~~'], S: ['~~'], MARK: ['=='], CODE: ['`','``','```']}[element.tagName];
      if (!choices && element.tagName !== 'A') continue;
      const records = mapping.records.filter(r => element.contains(r.node) && r.length);
      if (!records.length) continue;
      const first = records[0], last = records[records.length - 1];
      const start = mapping.starts[first.base], end = mapping.ends[last.base + last.length - 1];
      if (element.tagName === 'A') {
        if (selection.start === selection.end && selection.end === end && source.slice(end, end + 2) === '](') {
          const close = closing(source, end + 2, '(', ')', source.length);
          if (close >= 0) selection.start = selection.end = close + 1;
        } else { notice('Start a new paragraph outside the link, or edit its Markdown.'); return null; }
      } else {
        const delimiter = choices.find(d => source.slice(start - d.length, start) === d && source.slice(end, end + d.length) === d);
        if (!delimiter) { notice('Use the Markdown pane to split this formatting.'); return null; }
        delimiters.push({delimiter, start, end});
      }
    }
    if (delimiters.length) {
      const atEnd = selection.start === selection.end && delimiters.every(d => d.end === selection.end);
      const atStart = selection.start === selection.end && delimiters.every(d => d.start === selection.start);
      if (atEnd) selection.start = selection.end += delimiters.reduce((n,d) => n + d.delimiter.length, 0);
      else if (atStart) selection.start = selection.end -= delimiters.reduce((n,d) => n + d.delimiter.length, 0);
      else newline = delimiters.map(d => d.delimiter).join('') + newline + delimiters.slice().reverse().map(d => d.delimiter).join('');
    }
    return {selection, newline};
  }
  function replace(selection, text, mutate = true, raw = false, newList = false, display = text) {
    if (!selection) { notice('Edit this generated content in the Markdown pane.'); return false; }
    const {start, end, range} = selection;
    const code = (range.startContainer.parentElement || range.startContainer).closest('pre,code');
    const expected = state.source.slice(start, end);
    if (start !== end && !code) {
      const check = make(); inline(check, expected, 0, expected.length);
      const actual = make(); literal(actual, selection.text, 0, selection.text.length);
      if (canonical(check).text !== canonical(actual).text) {
        notice('This selection crosses a formatting boundary. Edit it in the Markdown pane.'); return false;
      }
    }
    const replacement = raw ? text : escapeText(text, code);
    post('replace', {start, length: end - start, expected, replacement});
    state.sequence++;
    state.source = state.source.slice(0, start) + replacement + state.source.slice(end);
    state.caret = start + replacement.length;
    let caretNode = null, caretHost = null;
    if (mutate) {
      range.deleteContents();
      const node = document.createTextNode(newList ? '' : display);
      caretNode = node;
      if (newList) {
        const li = range.startContainer.parentElement.closest('li');
        const host = document.createElement('li'); host.appendChild(node); host.appendChild(document.createElement('br'));
        caretHost = host;
        if (li) li.after(host); else { const paragraph = document.createElement('p'); paragraph.appendChild(node); range.insertNode(paragraph); }
      } else range.insertNode(node);
      range.setStart(node, node.length); range.collapse(true);
      const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range);
    }
    // The next typed character needs only this exact caret, not a document-wide
    // scan. Rebuild lazily if the user selects, navigates, or deletes text.
    mapping = null;
    fastCaret = caretNode ? {node: caretNode, host: caretHost, text: caretNode.data, offset: state.caret} : null;
    if (!newList && deferred) { deferred = false; post('deferRender', {active: false}); }
    return true;
  }
  function mirror() {
    selectionPending = false;
    if (composing || !state || !active) return;
    const selection = selected();
    if (selection) post('selection', {start: selection.start, length: selection.end - selection.start});
  }
  document.addEventListener('selectionchange', () => {
    if (selectionPending) return;
    selectionPending = true; requestAnimationFrame(mirror);
  });
  document.addEventListener('pointerdown', event => {
    if (!event.isTrusted || !state) return;
    active = true; if (!mapping) buildMap();
  });
  document.addEventListener('beforeinput', event => {
    if (!event.isTrusted) return;
    if (!state) { event.preventDefault(); return; }
    if (event.isComposing || event.inputType === 'insertCompositionText') return;
    event.preventDefault();
    if (event.inputType === 'insertFromComposition') return;
    if (/^history(Undo|Redo)$/.test(event.inputType)) { post(event.inputType); state = null; return; }
    let selection = selected();
    if (event.inputType.startsWith('delete')) {
      if (selection && selection.start === selection.end) {
        const backward = /Backward$/.test(event.inputType);
        getSelection().modify('extend', backward ? 'backward' : 'forward', /Word/.test(event.inputType) ? 'word' : 'character');
        selection = selected();
      }
      replace(selection, '');
    } else if (event.inputType === 'insertParagraph' || event.inputType === 'insertLineBreak') {
      const code = selection && selection.range.startContainer.parentElement.closest('pre');
      // WebKit reports ordinary Return as insertLineBreak in plaintext-only
      // hosts; use the trusted key modifier to distinguish Shift-Return.
      const paragraph = !softBreak; softBreak = false;
      let newline = code ? '\n' : paragraph ? '\n\n' : '  \n';
      let newList = false;
      if (selection && !code && paragraph) {
        const line = state.source.slice(state.source.lastIndexOf('\n', selection.start - 1) + 1, selection.start);
        const list = line.match(/^(\s*(?:>\s*)*)([-+*]|\d+[.)])\s+(?:\[[ xX]\]\s+)?/);
        if (list) {
          let marker = list[2];
          if (/^\d/.test(marker)) marker = (parseInt(marker, 10) + 1) + marker.slice(-1);
          newline = '\n' + list[1] + marker + ' ' + (/\[[ xX]\]/.test(list[0]) ? '[ ] ' : '');
          // Hoedown treats a trailing empty '-' as a setext underline. Keep
          // the optimistic empty list item until its first character arrives.
          newList = true;
          if (!line.slice(list[0].length).trim()) {
            // Return in an empty item ends the list.
            selection.start -= line.length;
            selection.text = state.source.slice(selection.start, selection.end);
            newline = '\n'; newList = false;
          }
        }
      }
      if (paragraph && !code) {
        const result = breakFormatting(selection, newline); if (!result) return;
        selection = result.selection; newline = result.newline;
      }
      if (newList && !deferred) { post('deferRender', {active: true}); deferred = true; }
      replace(selection, newline, true, true, newList, '\n');
    } else if (event.inputType === 'insertText' || event.inputType === 'insertReplacementText') replace(selection, event.data || '');
    else notice('Use the Markdown pane for this formatting operation.');
  });
  document.addEventListener('paste', event => {
    if (!event.isTrusted || !state) return;
    event.preventDefault(); replace(selected(), event.clipboardData.getData('text/plain'));
  });
  document.addEventListener('cut', event => {
    if (!event.isTrusted || !state) return;
    event.preventDefault(); const selection = selected();
    if (selection) { event.clipboardData.setData('text/plain', selection.text); replace(selection, ''); }
  });
  document.addEventListener('drop', event => { if (state) event.preventDefault(); });
  document.addEventListener('click', event => {
    // A normal click positions the caret in link text; Command-click retains
    // MacDown's existing link navigation behavior.
    if (state && event.target.closest('a') && !event.metaKey && !event.ctrlKey) event.preventDefault();
    if (state && !state.source.trim()) restoreCaret(state.source.length);
  });
  document.addEventListener('compositionstart', event => {
    if (!event.isTrusted || !state) return;
    composing = selected(); post('composition', {active: true});
  });
  document.addEventListener('compositionend', event => {
    if (!event.isTrusted || !state) return;
    const selection = composing; composing = null;
    if (event.data) replace(selection, event.data, false);
    post('composition', {active: false});
  });
  document.addEventListener('keydown', event => {
    if (!event.isTrusted || !state) return;
    active = true;
    if (event.key === 'Enter') { softBreak = event.shiftKey; return; }
    if (!(event.metaKey || event.ctrlKey)) return;
    const key = event.key.toLowerCase();
    if (key === 'z') { event.preventDefault(); post(event.shiftKey ? 'historyRedo' : 'historyUndo'); state = null; }
  });
  function restoreCaret(offset) {
    if (offset === null || offset === undefined || !state) return;
    if (!mapping) buildMap();
    for (const record of mapping.records) for (let i = 0; i < record.length; i++) {
      const index = record.base + i;
      if (mapping.starts[index] === offset || mapping.ends[index] === offset) {
        const range = document.createRange(); range.setStart(record.node, mapping.starts[index] === offset ? i : i + 1); range.collapse(true);
        const selection = getSelection(); selection.removeAllRanges(); selection.addRange(range); document.body.focus(); return;
      }
    }
    // Markdown omits empty paragraphs from HTML. Keep a temporary caret host
    // after Return, and map empty list items, until their first text is rendered.
    let previous = null, next = null, previousEnd = -1, nextStart = Infinity;
    for (const record of mapping.records) for (let i = 0; i < record.length; i++) {
      const a = mapping.starts[record.base + i], b = mapping.ends[record.base + i];
      if (b >= 0 && b <= offset && b >= previousEnd) { previous = record.node; previousEnd = b; }
      if (a >= offset && a < nextStart) { next = record.node; nextStart = a; }
    }
    if (/\S/.test(state.source.slice(Math.max(0, previousEnd), offset).replace(/(?:^|\n)\s*(?:[-+*]|\d+[.)])\s+(?:\[ \]\s*)?/g, ''))) return;
    let host = Array.from(document.querySelectorAll('li,p')).find(node => !node.textContent.trim() && !node.querySelector('img,script,iframe')
      && (!previous || previous.compareDocumentPosition(node) & Node.DOCUMENT_POSITION_FOLLOWING)
      && (!next || node.compareDocumentPosition(next) & Node.DOCUMENT_POSITION_FOLLOWING));
    if (!host) {
      host = document.createElement('p');
      const block = previous?.parentElement.closest('p,h1,h2,h3,h4,h5,h6,ul,ol,table,blockquote,pre');
      if (block) block.after(host); else document.body.prepend(host);
    }
    const node = document.createTextNode(''); host.appendChild(node);
    if (!host.querySelector('br')) host.appendChild(document.createElement('br'));
    const record = {node, base: 0, length: 0, emptyOffset: offset};
    mapping.records.push(record); mapping.byNode.set(node, record);
    if (!mapping.emptyHosts) mapping.emptyHosts = new WeakMap();
    mapping.emptyHosts.set(host, offset);
    const range = document.createRange(); range.setStart(node, 0); range.collapse(true);
    getSelection().removeAllRanges(); getSelection().addRange(range); document.body.focus();
  }
  window.__macdownPreviewPrepare = (source, token, offset, toc, caret) => {
    const retainedCaret = state?.source === source && fastCaret && document.body.contains(fastCaret.node)
      && fastCaret.node.data === fastCaret.text ? fastCaret : null;
    state = {source, token, offset, toc, sequence: 0, caret}; composing = null; deferred = false;
    mapping = null; fastCaret = null; active = caret !== null && caret !== undefined;
    enableEditing();
    if (active && retainedCaret && retainedCaret.offset === caret) { fastCaret = retainedCaret; return true; }
    if (active) {
      const separator = source.lastIndexOf('\n\n', Math.max(0, caret - 1));
      const start = Math.max(offset, separator < 0 ? 0 : separator + 2);
      const boundary = source.indexOf('\n\n', caret), end = boundary < 0 ? source.length : boundary;
      if (start <= caret && caret <= end && end - start < 16384) {
        const candidates = (window.__macdownPreviewPatchedNodes || []).filter(n => n.nodeType === Node.ELEMENT_NODE && !n.matches(generated));
        const segment = source.slice(start, end), projected = canonical(project(segment)).text;
        const matches = candidates.filter(n => canonical(collect(n).out).text === projected);
        if (matches.length === 1) buildMap({source: segment, root: matches[0], offset: start});
      }
    }
    restoreCaret(caret); return true;
  };
  window.__macdownPreviewMatches = (source, sequence) => !composing && (!state || state.source === source && state.sequence === sequence);
  window.__macdownPreviewInvalidate = () => { state = null; mapping = null; document.body.contentEditable = 'false'; };
  // Isolated-world hooks also let the local native regression probe exercise
  // the same mapping/mutation path without synthesizing trusted input events.
  window.__macdownPreviewSelection = selected;
  window.__macdownPreviewReplace = (text) => replace(selected(), text);
  window.__macdownPreviewProject = (source) => canonical(project(source)).text;
})();
