(() => {
  const out = { url: location.href, title: document.title, readyState: document.readyState };
  out.inputs = Array.from(document.querySelectorAll('input')).map(i => ({
    id: i.id, name: i.name, type: i.type,
    ph: i.placeholder, cls: (i.className || '').slice(0, 40), visible: !!(i.offsetWidth || i.offsetHeight)
  }));
  out.clickables = Array.from(document.querySelectorAll('button,a,div[class*=btn],span[class*=btn]'))
    .filter(e => (e.innerText || '').trim().length > 0 && (e.offsetWidth || e.offsetHeight))
    .slice(0, 15)
    .map(e => ({ tag: e.tagName, id: e.id, cls: (e.className || '').slice(0, 40), txt: (e.innerText || '').trim().slice(0, 24) }));
  out.iframes = Array.from(document.querySelectorAll('iframe')).map(f => f.src);
  out.bodyText = (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').slice(0, 300);
  return out;
})()
