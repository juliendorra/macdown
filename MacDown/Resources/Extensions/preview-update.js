// An editing fast path for the bundled template and scripts. Complex/custom
// scripts retain full navigation semantics, including their load events.
(() => {
  const initialHead = document.head.innerHTML;
  const initialScripts = JSON.stringify(Array.from(document.scripts, s => s.outerHTML));
  const simpleShell = !document.documentElement.attributes.length && !document.body.attributes.length
    && !/\son[a-z]+\s*=/i.test(document.body.innerHTML)
    && !document.querySelector('iframe, object, embed, audio, video');
  const headTemplate = document.createElement('template');
  const bodyTemplate = document.createElement('template');
  // Images and fonts can resize a retained page after its edit is complete.
  // Refresh native scroll geometry once per frame, without polling.
  let layoutPending = false;
  new ResizeObserver(() => {
    if (layoutPending) return;
    layoutPending = true;
    requestAnimationFrame(() => {
      layoutPending = false;
      window.webkit.messageHandlers.previewScroll.postMessage({layout: true});
    });
  }).observe(document.body);
  const codeSources = new WeakMap();
  const rememberCode = node => {
    if (node.nodeType === Node.ELEMENT_NODE &&
        (node.matches('pre, code') || node.querySelector('code')))
      codeSources.set(node, node.outerHTML);
  };
  Array.from(document.body.childNodes).forEach(rememberCode);
  const same = (oldNode, newNode) => codeSources.has(oldNode)
    ? newNode.nodeType === Node.ELEMENT_NODE && codeSources.get(oldNode) === newNode.outerHTML
    : oldNode.isEqualNode(newNode);

  window.__macdownUpdate = (html, resources) => {
    // Event attributes and arbitrary script/embedded-document lifecycles need
    // a real navigation. Conservative fallback is preferable to changing them.
    if (!simpleShell || /\son[a-z]+\s*=/i.test(html)) return false;
    // The default shell has no attributes on html/body. Restrict the shortcut
    // to that shape; custom templates keep the general navigation path.
    const parts = html.match(/^\s*<!DOCTYPE html>\s*<html>\s*<head>([\s\S]*?)<\/head>\s*<body>([\s\S]*?)<\/body>\s*<\/html>\s*$/i);
    if (!parts || /<\/?(?:html|head|body)\b/i.test(parts[2])) return false;
    headTemplate.innerHTML = parts[1];
    if (headTemplate.innerHTML !== initialHead || headTemplate.content.querySelector('script')) return false;
    // Inert fragments avoid allocating a new HTMLDocument, loader and style
    // context for every keystroke. Relative images resolve on insertion.
    bodyTemplate.innerHTML = parts[2];
    const next = bodyTemplate.content;
    const scripts = Array.from(next.querySelectorAll('script'));
    let compatible = !next.querySelector('iframe, object, embed, audio, video')
      && JSON.stringify(scripts.map(s => s.outerHTML)) === initialScripts;
    const resourceRoot = resources.replace(/\/?$/, '/');
    for (const script of scripts) {
      if (!script.src || !script.src.startsWith(resourceRoot) ||
          (!script.src.includes('/Prism/') && !script.src.endsWith('/Extensions/tasklist.js')) ||
          script.parentNode !== next) compatible = false;
    }
    if (!compatible) { bodyTemplate.innerHTML = ''; return false; }
    // Keep the original, already initialized scripts. Never execute parsed HTML
    // scripts again when adopting its content into the live page.
    next.querySelectorAll('script').forEach(s => s.remove());
    next.querySelectorAll('.task-list-item input').forEach(i => { i.disabled = true; });
    const oldNodes = Array.from(document.body.childNodes).filter(n => n.nodeName !== 'SCRIPT');
    const newNodes = Array.from(next.childNodes);
    let first = 0, oldEnd = oldNodes.length, newEnd = newNodes.length;
    while (first < oldEnd && first < newEnd && same(oldNodes[first], newNodes[first])) first++;
    while (oldEnd > first && newEnd > first && same(oldNodes[oldEnd - 1], newNodes[newEnd - 1])) {
      oldEnd--; newEnd--;
    }
    const anchor = oldNodes[oldEnd] || document.body.querySelector(':scope > script');
    const inserted = newNodes.slice(first, newEnd);
    const fragment = document.createDocumentFragment();
    inserted.forEach(node => { rememberCode(node); fragment.appendChild(node); });
    for (let i = first; i < oldEnd; i++) oldNodes[i].remove();
    document.body.insertBefore(fragment, anchor);
    // Highlight only inserted content. Untouched code and images keep their DOM
    // identity and loaded state. Full export/printing still sees the whole page.
    if (window.Prism) for (const node of inserted) {
      if (node.nodeType !== Node.ELEMENT_NODE) continue;
      if (node.matches('code[class*="language-"]')) Prism.highlightElement(node);
      node.querySelectorAll('code[class*="language-"], [class*="language-"] code').forEach(code => Prism.highlightElement(code));
    }
    bodyTemplate.innerHTML = ''; // Release unused fragment nodes immediately.
    return true;
  };
})();
