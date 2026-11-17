(() => {
  const r = { url: location.href, title: document.title };
  r.buttons = Array.from(document.querySelectorAll('button,a,div[class*=btn],span[class*=btn],input[type=button]'))
    .filter(e => (e.innerText || e.value || '').trim() && (e.offsetWidth || e.offsetHeight))
    .slice(0, 20)
    .map(e => ({
      tag: e.tagName, id: e.id,
      cls: (typeof e.className === 'string' ? e.className : '').slice(0, 50),
      txt: (e.innerText || e.value || '').trim().slice(0, 24)
    }));
  r.bodyText = (document.body ? document.body.innerText : '').replace(/\s+/g, ' ').slice(0, 400);
  return r;
})()
