(() => {
  const r = {};
  r.url = location.href;
  r.windowGlobals = Object.keys(window).filter(k => /^(OCS|GM_|GM\.|CAT_|scriptcat)/i.test(k) || /ocs/i.test(k)).slice(0, 40);
  r.domOcsish = Array.from(document.querySelectorAll('*')).filter(e => {
    const c = (typeof e.className === 'string' ? e.className : '');
    return /ocs/i.test(c) || /ocs/i.test(e.id || '') || /ocsjs/i.test(c);
  }).slice(0, 12).map(e => ({ tag: e.tagName, id: e.id, cls: (e.className || '').toString().slice(0, 60) }));
  r.shadowHosts = Array.from(document.querySelectorAll('*')).filter(e => e.shadowRoot).slice(0, 12)
    .map(e => ({ tag: e.tagName, id: e.id, cls: (e.className || '').toString().slice(0, 40) }));
  r.injectedScriptSrcs = Array.from(document.querySelectorAll('script')).map(s => s.src || '(inline#' + (s.id || '') + ')').slice(0, 25);
  r.bodyClasses = (document.body.className || '').slice(0, 120);
  r.userName = (function () {
    const el = document.querySelector('.user-name,.userName,#userName,[class*=user] h3');
    return el ? (el.innerText || '').trim().slice(0, 20) : null;
  })();
  return r;
})()
