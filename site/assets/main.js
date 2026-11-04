(() => {
  const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  document.getElementById("year").textContent = new Date().getFullYear();

  /* In-page links: land each section's headline just under the floating nav, and light up the
     nav item for the section on screen. */
  const nav = document.querySelector(".nav");
  const headOf = (el) => (el.matches("section") && el.querySelector(".section-head h2, .faq-intro h2")) || el;
  function goTo(hash, smooth = true) {
    if (hash === "#top" || hash === "#") { scrollTo({ top: 0, behavior: smooth && !reduce ? "smooth" : "auto" }); return; }
    const target = document.querySelector(hash);
    if (!target) return;
    const gap = nav.getBoundingClientRect().bottom + 36;
    const y = headOf(target).getBoundingClientRect().top + scrollY - gap;
    scrollTo({ top: Math.max(0, y), behavior: smooth && !reduce ? "smooth" : "auto" });
  }
  document.addEventListener("click", (e) => {
    const a = e.target.closest('a[href^="#"]');
    if (!a || a.getAttribute("href").length < 2 || e.metaKey || e.ctrlKey) return;
    e.preventDefault();
    goTo(a.getAttribute("href"));
    history.pushState(null, "", a.getAttribute("href"));
  });
  addEventListener("popstate", () => goTo(location.hash || "#top", false));
  if (location.hash) addEventListener("load", () => goTo(location.hash, false));

  const spy = [["#auto-start", ["#auto-start", "#moments"]], ["#copilot", ["#copilot"]], ["#faq", ["#faq"]]];
  const links = new Map(spy.map(([href]) => [href, document.querySelector(`.nav-links a[href="${href}"]`)]));
  const owner = new Map();
  spy.forEach(([href, ids]) => ids.forEach((id) => { const el = document.querySelector(id); if (el) owner.set(el, href); }));
  const visible = new Set();
  const spyIO = new IntersectionObserver((entries) => {
    for (const e of entries) e.isIntersecting ? visible.add(owner.get(e.target)) : visible.delete(owner.get(e.target));
    const current = spy.map(([h]) => h).find((h) => visible.has(h));
    links.forEach((a, h) => a && a.setAttribute("aria-current", String(h === current)));
  }, { rootMargin: "-40% 0px -55% 0px" });
  owner.forEach((_, el) => spyIO.observe(el));

  /* Reveal on scroll */
  const io = new IntersectionObserver((entries) => {
    for (const e of entries) if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
  }, { threshold: 0.15, rootMargin: "0px 0px -40px 0px" });
  document.querySelectorAll(".reveal").forEach((el) => io.observe(el));

  /* Run a loop only while its element is on screen */
  function whenVisible(el, start, stop) {
    new IntersectionObserver(([e]) => (e.isIntersecting ? start() : stop()), { threshold: 0.2 }).observe(el);
  }

  /* Prompter panels: same loop as the app (waiting, 3-2-1 ring, scroll at 140 wpm, restart).
     The hero reads the whole script; the auto-start one only counts in and reads a few seconds. */
  function prompter(panel, { playFor = Infinity, waitFor = 1600 } = {}) {
    const script = panel.querySelector(".script");
    const count = panel.querySelector(".countdown");
    const countNum = count.querySelector("b");
    const timer = panel.querySelector(".p-timer");
    const remain = panel.querySelector(".elapsed .rem");
    const progress = panel.querySelector(".progress i");
    const detect = panel.querySelector(".detect");
    const detectText = detect.querySelector("span");
    const win = panel.querySelector(".script-window");
    const words = script.textContent.trim().split(/\s+/).length;
    const total = (words / 140) * 60;
    const clock = (t) => { t = Math.max(0, Math.floor(t)); return `${Math.floor(t / 60)}:${String(t % 60).padStart(2, "0")}`; };
    let p = 0, played = 0, raf = 0, last = 0, running = false, phase = "idle", gen = 0;

    const place = () => {
      script.style.transform = `translateY(${win.clientHeight * 0.3 - p * script.offsetHeight}px)`;
      progress.style.width = `${p * 100}%`;
      timer.textContent = clock(p * total);
      remain.textContent = "\u2212" + clock(total - p * total);
    };
    const setActive = (on) => {
      panel.classList.toggle("active", on);
      detect.classList.toggle("on", on);
      detectText.textContent = on ? "Recording" : "Waiting for camera";
    };
    async function cycle(myGen) {
      phase = "ready"; p = 0; played = 0; place(); setActive(false);
      await sleep(waitFor);
      if (myGen !== gen) return;
      phase = "count"; setActive(true);
      for (const n of [3, 2, 1]) {
        if (myGen !== gen) return;
        countNum.textContent = n;
        count.classList.remove("show"); void count.offsetWidth; count.classList.add("show");
        await sleep(1000);
      }
      count.classList.remove("show");
      phase = "play";
    }
    function frame(t) {
      if (!running) return;
      const dt = last ? Math.min(t - last, 50) : 16; last = t;
      if (phase === "play") {
        p = Math.min(1, p + dt / 1000 / total); played += dt / 1000;
        place();
        if (p >= 1 || played >= playFor) { phase = "done"; const g = ++gen; sleep(1200).then(() => g === gen && cycle(g)); }
      }
      raf = requestAnimationFrame(frame);
    }
    addEventListener("resize", place);
    place();
    whenVisible(win, () => {
      if (running) return;
      running = true; last = 0; raf = requestAnimationFrame(frame);
      if (phase === "idle") cycle(++gen);
    }, () => { running = false; cancelAnimationFrame(raf); });
  }
  if (!reduce) {
    const hero = document.querySelector(".hero-prompter");
    const auto = document.querySelector(".auto-prompter");
    if (hero) prompter(hero);
    if (auto) prompter(auto, { playFor: 3.5, waitFor: 1800 });
  } else {
    document.querySelectorAll("[data-prompter] .script").forEach((el) => {
      el.style.transform = `translateY(${el.closest(".script-window").clientHeight * 0.3}px)`;
    });
  }

  /* Voice demo: words light up as they are "spoken" */
  const voice = document.getElementById("voiceDemo");
  if (voice && !reduce) {
    const words = [...voice.querySelectorAll(".w")];
    let i = 0, t = 0;
    const tick = () => {
      words.forEach((w, k) => { w.classList.toggle("said", k < i); w.classList.toggle("now", k === i); });
      const pause = words[i] && /\.$/.test(words[i].textContent) ? 900 : 260;
      i = i >= words.length ? 0 : i + 1;
      t = setTimeout(tick, i === 0 ? 1400 : pause);
    };
    whenVisible(voice, () => { if (!t) tick(); }, () => { clearTimeout(t); t = 0; });
  } else if (voice) {
    voice.querySelectorAll(".w").forEach((w) => w.classList.add("said"));
  }

  /* Copilot demo: the other person asks, the AI thinks, the answer is typed in */
  const co = document.getElementById("coPanel");
  if (co) {
    const out = document.getElementById("coReply");
    const strip = document.getElementById("coStrip");
    const placeholder = out.innerHTML;
    const convo = [
      ["me", "You", "Happy to walk you through pricing whenever you're ready."],
      ["them", "Them", "Thanks for the demo. What would this cost for a team of forty?"],
    ];
    const reply = "For forty people it's the Team plan, about $12 per seat a month. I can send a quote today, and we can start with a two-week pilot.";
    const line = ([cls, who, text]) => {
      const el = document.createElement("div");
      el.className = `ln ${cls}`;
      el.innerHTML = `<span class="tagx">${who}</span><span class="tx"></span>`;
      el.querySelector(".tx").textContent = text;
      return el;
    };
    let gen = 0, active = false;

    async function play() {
      const g = ++gen;
      const alive = () => g === gen && active;
      strip.textContent = ""; out.innerHTML = placeholder;
      await sleep(900);
      for (const c of convo) {
        if (!alive()) return;
        const el = line(c); strip.append(el);
        requestAnimationFrame(() => el.classList.add("in"));
        await sleep(1500);
      }
      if (!alive()) return;
      out.innerHTML = '<div class="think"><span><i></i><i></i><i></i></span>Thinking…</div>';
      await sleep(1300);
      out.textContent = "";
      const caret = document.createElement("span"); caret.className = "caret";
      const text = document.createTextNode(""); out.append(text, caret);
      for (const word of reply.split(" ")) {
        if (!alive()) return;
        text.data += (text.data ? " " : "") + word;
        await sleep(65);
      }
      await sleep(5000);
      if (alive()) play();
    }

    if (reduce) {
      convo.forEach((c) => { const el = line(c); el.classList.add("in"); strip.append(el); });
      out.textContent = reply;
    } else {
      whenVisible(co, () => { if (!active) { active = true; play(); } }, () => { active = false; gen++; });
    }
  }
})();
