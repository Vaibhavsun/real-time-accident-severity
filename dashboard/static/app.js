// Dashboard frontend
// - Loads initial data via HTTP /api/*
// - Subscribes to WebSocket /ws for live snapshot updates every 10s

const fmt = new Intl.NumberFormat("en-IN");


// ─────────────────── Chart.js setup ───────────────────
Chart.defaults.color = "#8a93b8";
Chart.defaults.borderColor = "#2a3358";
Chart.defaults.font.family = "-apple-system, BlinkMacSystemFont, Segoe UI, Roboto";

const weatherChart = new Chart(document.getElementById("chart-weather"), {
  type: "bar",
  data: {
    labels: [],
    datasets: [{
      label: "Accidents",
      data: [],
      backgroundColor: "rgba(91, 141, 239, 0.7)",
      borderColor: "#5b8def",
      borderWidth: 1,
    }, {
      label: "Fatal",
      data: [],
      backgroundColor: "rgba(255, 77, 109, 0.7)",
      borderColor: "#ff4d6d",
      borderWidth: 1,
    }],
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    indexAxis: "y",
    plugins: {
      legend: { labels: { color: "#e6e9f5" } },
    },
    scales: {
      x: { beginAtZero: true, grid: { color: "#2a3358" } },
      y: { grid: { display: false } },
    },
  },
});

const ageChart = new Chart(document.getElementById("chart-age"), {
  type: "doughnut",
  data: {
    labels: [],
    datasets: [{
      data: [],
      backgroundColor: ["#5b8def", "#34d399", "#ffa629", "#ff4d6d", "#a78bfa", "#22d3ee", "#fbbf24"],
      borderColor: "#141a30",
      borderWidth: 2,
    }],
  },
  options: {
    responsive: true,
    maintainAspectRatio: false,
    plugins: {
      legend: { position: "right", labels: { color: "#e6e9f5", boxWidth: 12 } },
    },
  },
});

// ─────────────────── KPI tiles + leaderboard ───────────────────
function setKpis(stats) {
  if (!stats) return;
  const set = (id, v) => document.getElementById(id).textContent = fmt.format(v || 0);
  set("kpi-accidents", stats.total_accidents);
  set("kpi-fatal", stats.total_fatal);
  set("kpi-serious", stats.total_serious);
  set("kpi-slight", stats.total_slight);
  set("kpi-casualties", stats.total_casualties);
  set("kpi-vehicles", stats.total_vehicles);
  if (stats.last_update) {
    const t = new Date(stats.last_update);
    document.getElementById("last-update").textContent = t.toLocaleTimeString();
  }
}

function renderDistricts(rows) {
  const list = document.getElementById("top-districts");
  list.innerHTML = "";
  rows.forEach((r, i) => {
    const li = document.createElement("li");
    li.innerHTML = `
      <span class="name">${i + 1}. ${r.district}</span>
      <span class="score">${fmt.format(r.weighted)} <span style="color:#8a93b8; font-weight:400; font-size:11px;">(${fmt.format(r.accidents)} acc)</span></span>
    `;
    list.appendChild(li);
  });
}

function renderWeather(rows) {
  weatherChart.data.labels = rows.map(r => r.weather);
  weatherChart.data.datasets[0].data = rows.map(r => Number(r.accidents));
  weatherChart.data.datasets[1].data = rows.map(r => Number(r.fatal));
  weatherChart.update();
}

function renderAge(rows) {
  ageChart.data.labels = rows.map(r => r.age_band);
  ageChart.data.datasets[0].data = rows.map(r => Number(r.vehicles));
  ageChart.update();
}

// ─────────────────── Latest tables (tabs) ───────────────────
const TABLE_CONFIG = {
  "kpi-geo": {
    url: "/api/kpi-geo?limit=50",
    columns: [
      { key: "event_date", label: "Date" },
      { key: "lat_grid", label: "Lat" },
      { key: "lon_grid", label: "Lon" },
      { key: "accident_count", label: "Total", num: true },
      { key: "fatal_count", label: "Fatal", num: true, cls: "severity-fatal" },
      { key: "serious_count", label: "Serious", num: true, cls: "severity-serious" },
      { key: "slight_count", label: "Slight", num: true, cls: "severity-slight" },
      { key: "total_casualties", label: "Casualties", num: true },
      { key: "total_vehicles", label: "Vehicles", num: true },
    ],
  },
  "conditions": {
    url: "/api/conditions?limit=50",
    columns: [
      { key: "event_date", label: "Date" },
      { key: "weather_conditions", label: "Weather" },
      { key: "light_conditions", label: "Light" },
      { key: "road_surface_conditions", label: "Road" },
      { key: "speed_limit", label: "Speed", num: true },
      { key: "accident_count", label: "Accidents", num: true },
      { key: "fatal_count", label: "Fatal", num: true, cls: "severity-fatal" },
      { key: "avg_severity", label: "Avg Severity", num: true },
    ],
  },
  "hotspots": {
    url: "/api/hotspots?limit=50",
    columns: [
      { key: "event_date", label: "Date" },
      { key: "local_authority_district", label: "District" },
      { key: "road_type", label: "Road Type" },
      { key: "urban_or_rural_area", label: "Urban/Rural" },
      { key: "weighted_count", label: "Weighted", num: true },
      { key: "accident_count", label: "Accidents", num: true },
    ],
  },
  "vehicle": {
    url: "/api/vehicle-profile?limit=50",
    columns: [
      { key: "year", label: "Year" },
      { key: "age_band_of_driver", label: "Age Band" },
      { key: "sex_of_driver", label: "Sex" },
      { key: "vehicle_type", label: "Vehicle" },
      { key: "vehicle_count", label: "Count", num: true },
      { key: "avg_age", label: "Avg Vehicle Age", num: true },
    ],
  },
  "demographics": {
    url: "/api/demographics?limit=50",
    columns: [
      { key: "processing_date", label: "Date" },
      { key: "age_band_of_driver", label: "Age Band" },
      { key: "sex_of_driver", label: "Sex" },
      { key: "vehicle_type", label: "Vehicle" },
      { key: "accident_severity", label: "Severity" },
      { key: "joined_count", label: "Count", num: true },
    ],
  },
};

async function loadTable(tab) {
  const cfg = TABLE_CONFIG[tab];
  if (!cfg) return;
  const head = document.getElementById("latest-head");
  const body = document.getElementById("latest-body");
  head.innerHTML = cfg.columns.map(c => `<th class="${c.num ? "num" : ""}">${c.label}</th>`).join("");
  body.innerHTML = `<tr><td colspan="${cfg.columns.length}" style="text-align:center; color:#8a93b8; padding:20px;">Loading…</td></tr>`;

  try {
    const res = await fetch(cfg.url);
    const rows = await res.json();
    if (!rows.length) {
      body.innerHTML = `<tr><td colspan="${cfg.columns.length}" style="text-align:center; color:#8a93b8; padding:20px;">No data yet</td></tr>`;
      return;
    }
    body.innerHTML = rows.map(r => "<tr>" + cfg.columns.map(c => {
      let v = r[c.key];
      if (v === null || v === undefined) v = "—";
      else if (c.num) v = fmt.format(v);
      const cls = [c.num ? "num" : "", c.cls || ""].filter(Boolean).join(" ");
      return `<td class="${cls}">${v}</td>`;
    }).join("") + "</tr>").join("");
  } catch (e) {
    body.innerHTML = `<tr><td colspan="${cfg.columns.length}" style="text-align:center; color:#ff4d6d; padding:20px;">Failed: ${e.message}</td></tr>`;
  }
}

document.querySelectorAll(".tab").forEach(btn => {
  btn.addEventListener("click", () => {
    document.querySelectorAll(".tab").forEach(b => b.classList.remove("active"));
    btn.classList.add("active");
    loadTable(btn.dataset.tab);
  });
});

// ─────────────────── WebSocket ───────────────────
let ws;
let wsReconnectTimer;

function connectWs() {
  const proto = location.protocol === "https:" ? "wss" : "ws";
  ws = new WebSocket(`${proto}://${location.host}/ws`);

  ws.onopen = () => {
    const el = document.getElementById("ws-status");
    el.textContent = "● live";
    el.className = "status online";
    // Send periodic pings to keep alive
    setInterval(() => { if (ws.readyState === 1) ws.send("ping"); }, 25000);
  };
  ws.onclose = () => {
    const el = document.getElementById("ws-status");
    el.textContent = "● disconnected";
    el.className = "status offline";
    clearTimeout(wsReconnectTimer);
    wsReconnectTimer = setTimeout(connectWs, 3000);
  };
  ws.onerror = () => { try { ws.close(); } catch {} };
  ws.onmessage = (ev) => {
    try {
      const msg = JSON.parse(ev.data);
      if (msg.type !== "snapshot") return;
      setKpis(msg.stats);
      renderDistricts(msg.top_districts || []);
      renderWeather(msg.top_weather || []);
      renderAge(msg.age_bands || []);
    } catch (e) { console.error("ws parse error", e); }
  };
}

// ─────────────────── ML prediction ───────────────────
function fillSelect(id, values) {
  const sel = document.getElementById(id);
  sel.innerHTML = values.map(v => `<option value="${v}">${v}</option>`).join("");
}

async function loadPredictFeatures() {
  const metaEl = document.getElementById("model-meta");
  try {
    const r = await fetch("/api/predict/features");
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      metaEl.textContent = `(model not ready: ${err.detail || r.statusText})`;
      document.getElementById("predict-btn").disabled = true;
      return;
    }
    const data = await r.json();
    fillSelect("age_band", data.feature_options.age_band_of_driver || []);
    fillSelect("sex", data.feature_options.sex_of_driver || []);
    fillSelect("vehicle_type", data.feature_options.vehicle_type || []);
    const acc = (data.accuracy_test * 100).toFixed(1);
    const trainedAt = new Date(data.trained_at).toLocaleString();
    metaEl.textContent = `(trained on ${fmt.format(data.n_samples)} samples · test acc ${acc}% · ${trainedAt})`;
    document.getElementById("predict-btn").disabled = false;
  } catch (e) {
    metaEl.textContent = `(failed to load: ${e.message})`;
    document.getElementById("predict-btn").disabled = true;
  }
}

document.getElementById("predict-form").addEventListener("submit", async (e) => {
  e.preventDefault();
  const btn = document.getElementById("predict-btn");
  const result = document.getElementById("predict-result");
  btn.disabled = true;
  btn.textContent = "Predicting…";
  result.classList.remove("show");

  const body = {
    age_band_of_driver: document.getElementById("age_band").value,
    sex_of_driver: document.getElementById("sex").value,
    vehicle_type: document.getElementById("vehicle_type").value,
  };

  try {
    const r = await fetch("/api/predict", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!r.ok) {
      const err = await r.json().catch(() => ({}));
      result.innerHTML = `<div class="error">Error: ${err.detail || r.statusText}</div>`;
      result.classList.add("show");
      return;
    }
    const data = await r.json();
    const cls = data.predicted_severity;
    const clsKey = (cls || "").toLowerCase();
    const probs = data.probabilities;
    const bars = ["Fatal", "Serious", "Slight"].map(k => {
      const p = probs[k] || 0;
      const pct = (p * 100).toFixed(1);
      return `
        <div class="prob-row">
          <span class="prob-label">${k}</span>
          <div class="prob-bar"><div class="prob-fill ${k.toLowerCase()}" style="width:${pct}%"></div></div>
          <span class="prob-pct">${pct}%</span>
        </div>`;
    }).join("");
    result.innerHTML = `
      <div class="pred-class ${clsKey}">Predicted: ${cls}</div>
      ${bars}
    `;
    result.classList.add("show");
  } catch (e) {
    result.innerHTML = `<div class="error">Request failed: ${e.message}</div>`;
    result.classList.add("show");
  } finally {
    btn.disabled = false;
    btn.textContent = "Predict";
  }
});

// ─────────────────── Initial load ───────────────────
async function bootstrap() {
  loadTable("kpi-geo");
  loadPredictFeatures();
  // Initial HTTP fetch for non-WS-pushed bits (the WS first snapshot covers most)
  try {
    const stats = await fetch("/api/stats").then(r => r.json());
    setKpis(stats);
  } catch {}
  connectWs();
}

bootstrap();
