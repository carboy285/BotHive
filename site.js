// Points the download buttons at the files in the latest release. If GitHub can't be reached, the buttons keep
// linking to the Releases page, so nothing breaks.
(async () => {
  const platform = /Mac/.test(navigator.platform) || /Macintosh/.test(navigator.userAgent) ? 'mac'
    : /Win/.test(navigator.platform) ? 'windows'
    : /iPhone|iPad/.test(navigator.userAgent) ? 'iphone' : '';
  if (platform) document.querySelector(`.download[data-platform="${platform}"]`)?.classList.add('suggested');
  const hero = document.getElementById('hero-download');
  if (hero && platform === 'mac') hero.textContent = 'Download for Mac';
  if (hero && platform === 'windows') hero.textContent = 'Download for Windows';

  const size = bytes => bytes > 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`;
  try {
    // The repository was renamed from opengrokbot to bothive; ask the new name first.
    let response;
    for (const repo of ['carboy285/bothive', 'carboy285/opengrokbot']) {
      response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, { headers: { Accept: 'application/vnd.github+json' } });
      if (response.status !== 404) break;
    }
    if (!response.ok) return;
    const release = await response.json();
    const assets = release.assets || [];
    const trusted = url => typeof url === 'string' && ['bothive', 'opengrokbot'].some(name => url.toLowerCase().startsWith(`https://github.com/carboy285/${name}/releases/download/`));
    const pick = (suffix, button, label) => {
      const asset = assets.find(item => item.name.endsWith(suffix) && trusted(item.browser_download_url));
      if (!asset) return;
      document.getElementById(button).href = asset.browser_download_url;
      document.getElementById(label).textContent = `${asset.name} · ${size(asset.size)}`;
      if (hero && ((platform === 'mac' && suffix.includes('mac')) || (platform === 'windows' && suffix.includes('Windows')))) hero.href = asset.browser_download_url;
    };
    pick('-mac-universal.dmg', 'download-mac', 'mac-file');
    pick('-Windows-x64-Setup.exe', 'download-windows', 'windows-file');
    const line = document.getElementById('release-line');
    const version = String(release.tag_name || '').replace(/^v/, '');
    if (line && version) {
      line.textContent = `Version ${version}, released ${new Date(release.published_at).toLocaleDateString(undefined, { day: 'numeric', month: 'long', year: 'numeric' })}. `;
      const notes = document.createElement('a'); notes.href = release.html_url; notes.textContent = "What's new";
      line.append(notes);
    }
  } catch { /* keep the Releases links */ }
})();
