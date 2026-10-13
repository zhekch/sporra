// The server compares named places and folded activities against an account
// baseline. This UI only presents its answer, including after a background sync.
const SHOW_MS = 14_000;
const CHECK_MS = 60_000;

export function mountWhatsNew({ load, ready = () => true, onOpenStats }) {
  const bar = document.getElementById('whats-new-bar');
  const titleEl = document.getElementById('whats-new-title');
  const detailEl = document.getElementById('whats-new-detail');
  const openBtn = document.getElementById('whats-new-open');
  const dismissBtn = document.getElementById('whats-new-dismiss');
  if (!bar) return { show: async () => {}, hide: () => {} };

  let timer = null, pending = false, generation = 0;
  let newActivities = 0, activityIds = [];
  const hide = () => {
    generation++;
    clearTimeout(timer);
    bar.hidden = true;
  };
  const show = async ({ quiet = false } = {}) => {
    if (pending) return;
    const request = generation;
    pending = true;
    try {
      const notice = await load(quiet);
      if (request !== generation || quiet || !notice?.show) return;
      newActivities = notice.activities;
      activityIds = notice.activityIds ?? [];
      titleEl.textContent = notice.title;
      detailEl.textContent = notice.detail;
      bar.hidden = false;
      clearTimeout(timer);
      timer = setTimeout(hide, SHOW_MS);
    } catch {
      // Offline or an older server: optional news must not interrupt the map.
    } finally {
      pending = false;
    }
  };
  const check = () => {
    if (!document.hidden && ready()) show();
  };
  setInterval(check, CHECK_MS);
  document.addEventListener('visibilitychange', check);
  openBtn?.addEventListener('click', () => {
    hide();
    onOpenStats?.(newActivities, activityIds);
  });
  dismissBtn?.addEventListener('click', hide);
  return { show, hide };
}
