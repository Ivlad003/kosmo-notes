// KosmoNotes landing — minimal JS:
// 1. Fetch the latest GitHub release tag and update the hero meta line
//    + the download CTA so it points at the actual asset rather than the
//    /releases/latest page.
// 2. Reveal-on-scroll for cards / steps (gentle fade-in, prefers-reduced-motion safe).

(() => {
  const REPO_OWNER = "Ivlad003";
  const REPO_NAME = "kosmo-notes";
  const ASSET_NAME = "KosmoNotes.zip"; // expected name of the release asset

  // ---------- Latest release fetcher ----------
  fetchLatestRelease().catch((err) => {
    console.warn("KosmoNotes: latest release lookup failed", err);
    setVersionLine("Latest release · check the Releases page");
  });

  async function fetchLatestRelease() {
    const url = `https://api.github.com/repos/${REPO_OWNER}/${REPO_NAME}/releases/latest`;
    const res = await fetch(url, { headers: { Accept: "application/vnd.github+json" } });
    if (!res.ok) throw new Error(`GitHub API ${res.status}`);
    const data = await res.json();
    const tag = data.tag_name || data.name || "";
    const date = data.published_at ? new Date(data.published_at).toLocaleDateString(undefined, { year: "numeric", month: "short", day: "numeric" }) : "";
    setVersionLine(`Latest: ${tag}${date ? " · " + date : ""}`);

    const asset = (data.assets || []).find((a) => a.name === ASSET_NAME) || (data.assets || [])[0];
    if (asset && asset.browser_download_url) {
      const dl = document.getElementById("downloadLatest");
      if (dl) dl.href = asset.browser_download_url;
    }
  }

  function setVersionLine(text) {
    const el = document.getElementById("versionLine");
    if (el) el.textContent = text;
  }

  // ---------- Reveal-on-scroll ----------
  // Tag everything we want to fade in, then let an IntersectionObserver flip the class.
  const targets = document.querySelectorAll(".card, .step, .feature__copy, .feature__media, .specs__grid > div, .hero__device");
  targets.forEach((el) => el.classList.add("reveal"));

  if ("IntersectionObserver" in window && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            entry.target.classList.add("is-visible");
            io.unobserve(entry.target);
          }
        });
      },
      { rootMargin: "0px 0px -10% 0px", threshold: 0.05 }
    );
    targets.forEach((el) => io.observe(el));
  } else {
    targets.forEach((el) => el.classList.add("is-visible"));
  }
})();
