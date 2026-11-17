(() => {
  const out = { checkboxLike: [], protocolArea: null, loginBtnVisible: false };
  // 所有可能是复选框的元素
  Array.from(document.querySelectorAll('input[type=checkbox], i[class*=check], span[class*=check], div[class*=check], .agree, [id*=agree], [id*=protocol]'))
    .forEach(e => {
      out.checkboxLike.push({
        tag: e.tagName, id: e.id,
        cls: (e.className || '').toString().slice(0, 60),
        checked: e.checked, checkedAttr: e.getAttribute && e.getAttribute('checked'),
        hasOn: /on|checked|active|selected/i.test((e.className || '').toString()),
        visible: !!(e.offsetWidth || e.offsetHeight),
        txt: (e.textContent || '').trim().slice(0, 40)
      });
    });
  // 协议行附近的元素
  const walker = Array.from(document.querySelectorAll('label,div,p,span'));
  const hit = walker.find(e => (e.textContent || '').includes('我已阅读并同意'));
  if (hit) {
    out.protocolArea = {
      tag: hit.tagName,
      cls: (hit.className || '').toString().slice(0, 60),
      html: hit.outerHTML.slice(0, 500)
    };
  }
  const btn = document.querySelector('#loginBtn');
  out.loginBtnVisible = !!(btn && (btn.offsetWidth || btn.offsetHeight));
  out.needVcode = (document.querySelector('#needVcode') || {}).value;
  return out;
})()
