(() => {
  const btns = Array.from(document.querySelectorAll('button'));
  const target = btns.find(b => (b.innerText || '').trim() === '更新')
    || btns.find(b => (b.innerText || '').trim() === '安装');
  if (!target) return { ok: false, reason: 'no-install-button', seen: btns.map(b => (b.innerText || '').trim()) };
  target.click();
  return { ok: true, clicked: (target.innerText || '').trim() };
})()
