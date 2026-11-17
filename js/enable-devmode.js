(() => {
  const findDeep = (sel, root, depth) => {
    root = root || document;
    depth = depth || 0;
    if (depth > 8 || !root) return null;
    try { const h = root.querySelector(sel); if (h) return h; } catch (e) {}
    let all = [];
    try { all = root.querySelectorAll('*'); } catch (e) { return null; }
    for (const e of all) {
      if (e.shadowRoot) {
        const r = findDeep(sel, e.shadowRoot, depth + 1);
        if (r) return r;
      }
    }
    return null;
  };

  const isOn = (el) => el.checked === true
    || el.getAttribute('aria-pressed') === 'true'
    || el.hasAttribute('checked');

  const el = findDeep('#devMode');
  if (!el) {
    return { ok: false, reason: 'devmode-toggle-not-found', hasManager: !!document.querySelector('extensions-manager') };
  }
  if (isOn(el)) return { ok: true, already: true, tag: el.tagName };

  el.click();
  return {
    ok: true, clicked: true, tag: el.tagName,
    before: { checked: el.checked, aria: el.getAttribute('aria-pressed') },
    after: { checked: el.checked, aria: el.getAttribute('aria-pressed') }
  };
})()
