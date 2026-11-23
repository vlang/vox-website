(() => {
  const block = document.querySelector('[data-download-os]');
  if (!block) return;

  const slot = block.querySelector('[data-primary-slot]');
  const options = block.querySelector('.download-bar__options');
  const toggle = block.querySelector('.download-bar__toggle');
  const mac = block.querySelector('.first-page__download-button--macos');
  const linux = block.querySelector('.first-page__download-button--linux');
  const arch = block.querySelector('.first-page__download-button--arch');
  if (!slot || !options || !toggle || !mac || !linux) return;

  // All platform buttons open the published latest release page. The source
  // hrefs stay as V routes so server-side rendering and its tests are unchanged.
  const latest = 'https://github.com/vox-browser/vox/releases/latest';
  [mac, linux, arch].filter(Boolean).forEach(function (link) { link.href = latest; });

  const ua = navigator.userAgent;
  const platform = navigator.userAgentData?.platform || navigator.platform || '';
  const isLinux = (block.dataset.downloadOs === 'linux' || /linux/i.test(`${platform} ${ua}`)) && !/android/i.test(ua);
  const preferred = isLinux ? linux : mac;

  function setOpen(open) {
    options.hidden = !open;
    toggle.setAttribute('aria-expanded', String(open));
  }

  function setArchitecture(architecture) {
    const arch = /arm|aarch64/i.test(architecture) ? 'arm64' : 'amd64';
    linux.querySelector('.download-button__size')?.remove();
    const size = linux.dataset[`${arch}Size`];
    if (size) {
      const label = document.createElement('span');
      label.className = 'download-button__size';
      label.textContent = size;
      linux.append(label);
    }
  }

  // Keep the detected platform as the visible primary action; the remaining
  // downloads stay in the dropdown. Moving the nodes preserves their labels.
  if (slot.firstElementChild !== preferred) {
    const previous = slot.firstElementChild;
    slot.replaceChildren(preferred);
    if (previous) options.prepend(previous);
  }
  block.dataset.downloadOs = isLinux ? 'linux' : 'macos';
  setArchitecture(`${platform} ${ua}`);

  if (isLinux && navigator.userAgentData?.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(['architecture'])
      .then(({ architecture }) => { if (architecture) setArchitecture(architecture); })
      .catch(() => {});
  }

  toggle.addEventListener('click', () => setOpen(options.hidden));
  document.addEventListener('click', (event) => {
    if (!block.contains(event.target)) setOpen(false);
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') setOpen(false);
  });
})();
