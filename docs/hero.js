// Hero spectrum ribbon: a ring grows, the strip flashes red, an amber notch
// lands on it, the strip goes amber, the notch releases, the strip returns to green.
(function () {
  "use strict";

  var hero = document.querySelector(".hero");
  var canvas = document.getElementById("ribbon");
  var readout = document.getElementById("readout");
  var pauseBtn = document.getElementById("pause");
  if (!hero || !canvas || !canvas.getContext) return;

  var ctx = canvas.getContext("2d");
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");

  var COLORS = {
    accent: "#4DA3FF",
    working: "#F2B544",
    ring: "#FF4D4D",
    grid: "rgba(154, 164, 178, 0.12)",
    label: "#F5F7FA"
  };

  var BINS = 220;
  var F_MIN = 100;
  var F_MAX = 20000;
  var LOG_SPAN = Math.log(F_MAX / F_MIN);
  var CYCLE = 9; // seconds
  var RING_FREQS = [2480, 630, 3150, 1250, 4000];

  // Timeline within one cycle, in seconds.
  var T_GROW = 1.4;    // ring starts growing
  var T_DETECT = 2.1;  // detector fires: strip turns red
  var T_NOTCH = 2.25;  // notch lands
  var T_DEEPEN = 2.7;  // notch deepens to -12 dB
  var T_AMBER = 3.4;   // red state expires, strip turns amber
  var T_RELEASE = 5.6; // notch starts releasing
  var T_SAFE = 7.4;    // notch gone, strip green

  var smooth = new Float32Array(BINS);
  var running = true;
  var visible = true;
  var startTime = performance.now();
  var pausedAt = 0;
  var lastState = "";
  var lastText = "";

  function freqAt(i) { return F_MIN * Math.exp((i / (BINS - 1)) * LOG_SPAN); }
  function xForFreq(f, w) { return (Math.log(f / F_MIN) / LOG_SPAN) * w; }
  function binForFreq(f) { return (Math.log(f / F_MIN) / LOG_SPAN) * (BINS - 1); }
  function clamp(v, a, b) { return v < a ? a : v > b ? b : v; }
  function ease(t) { t = clamp(t, 0, 1); return t * t * (3 - 2 * t); }
  function fmtFreq(f) { return f >= 1000 ? (f / 1000).toFixed(2).replace(/0$/, "") + " kHz" : f + " Hz"; }

  // Voice-like envelope: formant bumps that drift slowly, rolling off above 5 kHz.
  function voiceEnvelope(f, t) {
    var lf = Math.log(f);
    var bump = function (fc, width, gain) {
      var d = (lf - Math.log(fc)) / width;
      return gain * Math.exp(-d * d);
    };
    var syl = 0.75 + 0.25 * Math.sin(t * 3.1) * Math.sin(t * 1.3 + 1);
    var v =
      bump(220 + 30 * Math.sin(t * 0.9), 0.45, 0.62) +
      bump(650 + 120 * Math.sin(t * 1.7), 0.35, 0.5 * syl) +
      bump(1300 + 260 * Math.sin(t * 1.1 + 2), 0.32, 0.38 * syl) +
      bump(2900 + 300 * Math.sin(t * 0.7), 0.3, 0.26 * syl) +
      0.12;
    var roll = f > 5000 ? Math.exp(-(lf - Math.log(5000)) * 0.9) : 1;
    return v * roll;
  }

  function phase(tc) {
    var ringAmp = 0, depth = 0, state = "safe";
    if (tc >= T_GROW && tc < T_NOTCH) {
      ringAmp = 0.06 * Math.exp((tc - T_GROW) * 4.6); // exponential growth
    } else if (tc >= T_NOTCH && tc < T_NOTCH + 0.8) {
      var peak = 0.06 * Math.exp((T_NOTCH - T_GROW) * 4.6);
      ringAmp = peak * Math.exp(-(tc - T_NOTCH) * 6);
    }
    if (tc >= T_NOTCH && tc < T_SAFE) {
      if (tc < T_DEEPEN) depth = 6;
      else if (tc < T_RELEASE) depth = 6 + 6 * ease((tc - T_DEEPEN) / 0.3);
      else depth = 12 * (1 - ease((tc - T_RELEASE) / (T_SAFE - T_RELEASE)));
    }
    if (tc >= T_DETECT && tc < T_AMBER) state = "ring";
    else if (tc >= T_AMBER && tc < T_SAFE) state = "working";
    return { ringAmp: ringAmp, depth: depth, state: state };
  }

  function textFor(tc, p, freq) {
    if (p.state === "ring") return "Ring caught at " + fmtFreq(freq);
    if (p.state === "working") {
      if (tc >= T_RELEASE) return "Ring gone. Notch at " + fmtFreq(freq) + " releasing";
      return "Notch at " + fmtFreq(freq) + ", −" + Math.round(p.depth) + " dB. Voice passing";
    }
    return "Stable. No notches active";
  }

  function resize() {
    var dpr = Math.min(window.devicePixelRatio || 1, 2);
    var w = canvas.clientWidth;
    var h = canvas.clientHeight;
    if (!w || !h) return;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  }

  function draw(t, freezeNoise) {
    var w = canvas.clientWidth;
    var h = canvas.clientHeight;
    if (!w || !h) return;

    var cycleIndex = Math.floor(t / CYCLE);
    var tc = t - cycleIndex * CYCLE;
    var freq = RING_FREQS[cycleIndex % RING_FREQS.length];
    var p = phase(tc);
    var ringBin = binForFreq(freq);

    ctx.clearRect(0, 0, w, h);

    // Grid: decades and level lines.
    ctx.strokeStyle = COLORS.grid;
    ctx.lineWidth = 1;
    ctx.beginPath();
    [1000, 10000].forEach(function (f) {
      var x = Math.round(xForFreq(f, w)) + 0.5;
      ctx.moveTo(x, 0); ctx.lineTo(x, h);
    });
    for (var g = 1; g < 4; g++) {
      var y = Math.round((h * g) / 4) + 0.5;
      ctx.moveTo(0, y); ctx.lineTo(w, y);
    }
    ctx.stroke();

    // Spectrum, with the notch carved out of it.
    var top = h * 0.08;
    var usable = h - top;
    var pts = new Array(BINS);
    for (var i = 0; i < BINS; i++) {
      var f = freqAt(i);
      var target = voiceEnvelope(f, t) * (0.9 + 0.1 * Math.sin(i * 0.55 + t * 7) * Math.sin(i * 0.21 - t * 4));
      if (p.depth > 0) {
        var d = (i - ringBin) / 1.6;
        target *= 1 - (p.depth / 18) * 0.85 * Math.exp(-d * d);
      }
      smooth[i] = freezeNoise ? target : smooth[i] + (target - smooth[i]) * 0.35;
      pts[i] = [(i / (BINS - 1)) * w, h - clamp(smooth[i], 0, 1) * usable];
    }

    var fill = ctx.createLinearGradient(0, top, 0, h);
    fill.addColorStop(0, "rgba(77, 163, 255, 0.42)");
    fill.addColorStop(1, "rgba(77, 163, 255, 0.04)");
    ctx.beginPath();
    ctx.moveTo(0, h);
    for (i = 0; i < BINS; i++) ctx.lineTo(pts[i][0], pts[i][1]);
    ctx.lineTo(w, h);
    ctx.closePath();
    ctx.fillStyle = fill;
    ctx.fill();

    ctx.beginPath();
    for (i = 0; i < BINS; i++) {
      if (i === 0) ctx.moveTo(pts[i][0], pts[i][1]);
      else ctx.lineTo(pts[i][0], pts[i][1]);
    }
    ctx.strokeStyle = COLORS.accent;
    ctx.lineWidth = 2;
    ctx.lineJoin = "round";
    ctx.stroke();

    var rx = xForFreq(freq, w);

    // Detector flash: red bar at the detected frequency for 300 ms.
    if (tc >= T_DETECT && tc < T_DETECT + 0.3) {
      ctx.fillStyle = "rgba(255, 77, 77, " + (0.35 * (1 - (tc - T_DETECT) / 0.3)).toFixed(3) + ")";
      ctx.fillRect(rx - 10, 0, 20, h);
    }

    // The ring itself: a narrow, growing spike.
    if (p.ringAmp > 0.01) {
      var base = h - clamp(voiceEnvelope(freq, t), 0, 1) * usable;
      var peakY = Math.max(top * 0.4, base - p.ringAmp * usable);
      ctx.beginPath();
      ctx.moveTo(rx - 9, h);
      ctx.lineTo(rx - 9, base + 6);
      ctx.quadraticCurveTo(rx - 2, base, rx, peakY);
      ctx.quadraticCurveTo(rx + 2, base, rx + 9, base + 6);
      ctx.lineTo(rx + 9, h);
      ctx.closePath();
      ctx.fillStyle = "rgba(255, 77, 77, 0.28)";
      ctx.fill();
      ctx.beginPath();
      ctx.moveTo(rx - 9, base + 6);
      ctx.quadraticCurveTo(rx - 2, base, rx, peakY);
      ctx.quadraticCurveTo(rx + 2, base, rx + 9, base + 6);
      ctx.strokeStyle = COLORS.ring;
      ctx.lineWidth = 2.5;
      ctx.stroke();
    }

    // Notch marker: vertical amber line whose height is depth.
    if (p.depth > 0.2) {
      var mh = (p.depth / 18) * (h * 0.9);
      ctx.fillStyle = COLORS.working;
      ctx.fillRect(Math.round(rx) - 1.5, h - mh, 3, mh);
      ctx.beginPath();
      ctx.arc(rx, h - mh, 4, 0, Math.PI * 2);
      ctx.fill();
      ctx.font = "600 12px Archivo, system-ui, sans-serif";
      ctx.textBaseline = "middle";
      var label = "−" + Math.round(p.depth) + " dB";
      var lw = ctx.measureText(label).width;
      var lx = rx + 10 + lw > w ? rx - 10 - lw : rx + 10;
      ctx.fillText(label, lx, h - mh);
    }

    if (p.state !== lastState) {
      hero.setAttribute("data-state", p.state);
      lastState = p.state;
    }
    var text = textFor(tc, p, freq);
    if (text !== lastText) {
      readout.textContent = text;
      lastText = text;
    }
  }

  function frame(now) {
    if (!running || !visible || reduceMotion.matches) return;
    draw((now - startTime) / 1000, false);
    requestAnimationFrame(frame);
  }

  function start() {
    if (reduceMotion.matches) return;
    startTime = performance.now() - pausedAt * 1000;
    requestAnimationFrame(frame);
  }

  function renderStill() {
    // A representative frame: notch holding, strip amber.
    draw(3.9, true);
  }

  pauseBtn.addEventListener("click", function () {
    running = !running;
    pauseBtn.setAttribute("aria-pressed", String(!running));
    pauseBtn.textContent = running ? "Pause" : "Play";
    if (running) start();
    else pausedAt = (performance.now() - startTime) / 1000;
  });

  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      var nowVisible = entries[0].isIntersecting;
      if (nowVisible && !visible) { visible = true; if (running) start(); }
      else if (!nowVisible && visible) {
        visible = false;
        if (running) pausedAt = (performance.now() - startTime) / 1000;
      }
    }).observe(canvas);
  }

  function applyMotionPreference() {
    pauseBtn.hidden = reduceMotion.matches;
    if (reduceMotion.matches) renderStill();
    else start();
  }

  window.addEventListener("resize", function () {
    resize();
    if (reduceMotion.matches) renderStill();
    else if (!running) draw(pausedAt, true);
  });
  if (reduceMotion.addEventListener) reduceMotion.addEventListener("change", applyMotionPreference);

  resize();
  // ?still=<seconds> renders one fixed frame (used for screenshots).
  var still = parseFloat(new URLSearchParams(location.search).get("still"));
  if (!isNaN(still)) {
    running = false;
    pausedAt = still;
    pauseBtn.hidden = true;
    draw(still, true);
    return;
  }
  applyMotionPreference();
})();
