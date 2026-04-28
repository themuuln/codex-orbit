#!/usr/bin/env node

const fs = require("node:fs");
const fsp = require("node:fs/promises");
const http = require("node:http");
const net = require("node:net");
const path = require("node:path");
const { execFileSync, spawn } = require("node:child_process");
const process = require("node:process");

function usage() {
  console.error(
    [
      "Usage:",
      "  codex-orbit-hot.js serve (--accounts-dir <dir> | --sessions-file <path> [--provider <name>]) --account <acct> --app-port <port> --control-port <port> --state-file <path> --app-log-file <path> [--codex-bin <path>] [--auto-switch <0|1>] [--auto-switch-interval <seconds>]",
      "  codex-orbit-hot.js start (--accounts-dir <dir> | --sessions-file <path> [--provider <name>]) [--account <acct>] --app-port <port> --control-port <port> --state-file <path> --log-file <path> --app-log-file <path> [--allow-port-fallback <0|1>] [--idle-seconds <seconds>] [--codex-bin <path>] [--auto-switch <0|1>] [--auto-switch-interval <seconds>]",
      "  codex-orbit-hot.js status --state-file <path> [--json]",
      "  codex-orbit-hot.js switch --state-file <path> --account <acct>",
      "  codex-orbit-hot.js autoswitch --state-file <path> --enabled <0|1> [--interval <seconds>]",
      "  codex-orbit-hot.js attach-start --state-file <path> --client-id <id> [--pid <pid>]",
      "  codex-orbit-hot.js attach-stop --state-file <path> --client-id <id>",
      "  codex-orbit-hot.js stop --state-file <path>",
    ].join("\n"),
  );
}

function parseArgs(argv) {
  const [command, ...rest] = argv;
  const options = {};

  for (let idx = 0; idx < rest.length; idx += 1) {
    const arg = rest[idx];
    if (!arg.startsWith("--")) {
      throw new Error(`unexpected argument: ${arg}`);
    }
    const key = arg.slice(2);
    if (key === "json") {
      options.json = true;
      continue;
    }
    if (idx + 1 >= rest.length) {
      throw new Error(`missing value for --${key}`);
    }
    options[key] = rest[idx + 1];
    idx += 1;
  }

  return { command, options };
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function ensureDirSync(target) {
  fs.mkdirSync(target, { recursive: true });
}

function toBooleanFlag(value) {
  if (value == null) {
    return false;
  }
  return !["0", "false", "no", "off", ""].includes(String(value).toLowerCase());
}

function toPositiveInteger(value, fallback) {
  const numeric = Number(value);
  if (!Number.isFinite(numeric) || numeric < 0) {
    return fallback;
  }
  return Math.floor(numeric);
}

function readJsonFileSync(file) {
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

async function readJsonFile(file) {
  return JSON.parse(await fsp.readFile(file, "utf8"));
}

async function writeJsonFile(file, payload) {
  await fsp.mkdir(path.dirname(file), { recursive: true });
  const temp = `${file}.tmp.${process.pid}.${Date.now()}`;
  await fsp.writeFile(temp, `${JSON.stringify(payload, null, 2)}\n`, {
    encoding: "utf8",
    mode: 0o600,
  });
  await fsp.rename(temp, file);
}

async function removeFile(file) {
  try {
    await fsp.unlink(file);
  } catch (error) {
    if (error && error.code !== "ENOENT") {
      throw error;
    }
  }
}

function accountAuthFile(accountsDir, account) {
  return path.join(accountsDir, account, "auth.json");
}

function sessionHomeAuthFile(homeDir) {
  return path.join(homeDir, "auth.json");
}

function providerName(value) {
  return value || "codex";
}

function buildSessionSource(options) {
  const accountsDir = options["accounts-dir"];
  const sessionsFile = options["sessions-file"];

  if (accountsDir && sessionsFile) {
    throw new Error("choose one of --accounts-dir or --sessions-file");
  }
  if (accountsDir) {
    return {
      kind: "accounts-dir",
      accountsDir: path.resolve(accountsDir),
      provider: "codex",
    };
  }
  if (sessionsFile) {
    return {
      kind: "sessions-file",
      sessionsFile: path.resolve(sessionsFile),
      provider: providerName(options.provider),
    };
  }

  throw new Error("missing --accounts-dir or --sessions-file");
}

function appendSessionSourceArgs(target, sessionSource) {
  if (sessionSource.kind === "accounts-dir") {
    target.push("--accounts-dir", sessionSource.accountsDir);
    return;
  }
  target.push("--sessions-file", sessionSource.sessionsFile, "--provider", sessionSource.provider);
}

function loadSessionRecord(sessionSource, account) {
  const store = readJsonFileSync(sessionSource.sessionsFile);
  const sessions = Array.isArray(store && store.sessions) ? store.sessions : [];
  const row = sessions.find(
    (item) =>
      item &&
      item.provider === sessionSource.provider &&
      item.name === account,
  );
  if (!row) {
    throw new Error(`unknown session ${sessionSource.provider}/${account}`);
  }
  if (!row.home) {
    throw new Error(`session ${sessionSource.provider}/${account} does not have a home path`);
  }
  return row;
}

function resolveAccountHome(sessionSource, account) {
  if (sessionSource.kind === "accounts-dir") {
    return path.resolve(sessionSource.accountsDir, account);
  }
  return path.resolve(loadSessionRecord(sessionSource, account).home);
}

function listSourceAccounts(sessionSource) {
  if (sessionSource.kind === "accounts-dir") {
    return fs
      .readdirSync(sessionSource.accountsDir, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && !entry.name.startsWith("."))
      .map((entry) => entry.name)
      .sort();
  }

  const store = readJsonFileSync(sessionSource.sessionsFile);
  const sessions = Array.isArray(store && store.sessions) ? store.sessions : [];
  return sessions
    .filter((item) => item && item.provider === sessionSource.provider && item.name)
    .map((item) => item.name)
    .sort();
}

function keychainSupported() {
  return process.platform === "darwin" && (process.env.CODEX_ORBIT_KEYCHAIN_ENABLED || "1") !== "0";
}

function keychainServiceName() {
  return process.env.CODEX_ORBIT_KEYCHAIN_SERVICE || "ai.factory.codex-orbit.auth";
}

function securityBinary() {
  return process.env.CODEX_ORBIT_SECURITY_BIN || "security";
}

function pythonBinary() {
  return process.env.PYTHON3_BIN || "python3";
}

function quotaHelperPath() {
  return (
    process.env.CODEX_ORBIT_QUOTA_HELPER ||
    process.env.CODEX_ROTATOR_QUOTA_HELPER ||
    process.env.CLISESS_QUOTA_HELPER ||
    path.join(__dirname, "codex-orbit-quota.py")
  );
}

function loadSessionAuth(homeDir, label) {
  const authFile = sessionHomeAuthFile(homeDir);
  if (fs.existsSync(authFile)) {
    return readJsonFileSync(authFile);
  }
  if (!keychainSupported()) {
    throw new Error(`${label} does not have auth.json`);
  }
  const accountDir = path.resolve(homeDir);
  try {
    const output = execFileSync(
      securityBinary(),
      ["find-generic-password", "-s", keychainServiceName(), "-a", accountDir, "-w"],
      { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] },
    );
    return JSON.parse(output);
  } catch (error) {
    const detail = `${error.stdout || ""}\n${error.stderr || ""}`.toLowerCase();
    if (detail.includes("could not be found") || detail.includes("not be found in the keychain")) {
      throw new Error(`${label} does not have auth.json or a matching keychain entry`);
    }
    throw error;
  }
}

function loadChatgptTokens(homeDir, label) {
  const auth = loadSessionAuth(homeDir, label);
  const tokens = auth.tokens || {};
  const accessToken =
    tokens.access_token || tokens.accessToken || auth.access_token || auth.accessToken;
  const idToken = tokens.id_token || tokens.idToken || auth.id_token || auth.idToken;
  const chatgptAccountId =
    tokens.account_id ||
    tokens.accountId ||
    auth.account_id ||
    auth.accountId ||
    auth.chatgpt_account_id ||
    auth.chatgptAccountId;

  if (!accessToken || !idToken) {
    throw new Error(
      `${label} does not have ChatGPT access_token/id_token credentials in auth.json`,
    );
  }

  if (!chatgptAccountId) {
    throw new Error(`${label} does not have a ChatGPT account id in auth.json`);
  }

  return { accessToken, idToken, chatgptAccountId };
}

function parseQuotaSnapshot(tsv) {
  const text = String(tsv || "").trim();
  if (!text) {
    return { remaining: null, available: false, deactivated: false };
  }
  const fields = text.split("\x1f");
  const remaining = Number(fields[7]);
  return {
    remaining: Number.isFinite(remaining) ? remaining : null,
    available: true,
    deactivated: false,
  };
}

function quotaStateForHome(homeDir) {
  const helper = quotaHelperPath();
  if (!fs.existsSync(helper)) {
    return { remaining: null, available: false, deactivated: false };
  }

  try {
    const output = execFileSync(
      pythonBinary(),
      [helper, "snapshot", "--account-dir", homeDir, "--format", "tsv", "--source", "oauth"],
      {
        encoding: "utf8",
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    return parseQuotaSnapshot(output);
  } catch (error) {
    const detail = `${error.stdout || ""}\n${error.stderr || ""}`;
    if (detail.includes("deactivated_workspace")) {
      return { remaining: 0, available: false, deactivated: true };
    }
    return { remaining: null, available: false, deactivated: false };
  }
}

function formatActionLabel(action) {
  switch (action) {
    case "started":
      return "fresh start";
    case "switched":
      return "switched";
    case "reused":
      return "reused";
    default:
      return action || "-";
  }
}

function stateToText(payload) {
  const lines = [
    `Running: ${payload.running ? "yes" : "no"}`,
    `Ready: ${payload.ready ? "yes" : "no"}`,
    `Account: ${payload.account || "-"}`,
    `App URL: ${payload.app_url || "-"}`,
    `Control URL: ${payload.control_url || "-"}`,
  ];

  if (payload.controller_pid) {
    lines.push(`Controller PID: ${payload.controller_pid}`);
  }
  if (payload.app_server_pid) {
    lines.push(`App server PID: ${payload.app_server_pid}`);
  }
  if (payload.auth_mode) {
    lines.push(`Auth mode: ${payload.auth_mode}`);
  }
  if (payload.auto_switch) {
    lines.push(`Auto-switch: ${payload.auto_switch.enabled ? "enabled" : "disabled"}`);
    if (payload.auto_switch.interval_seconds) {
      lines.push(`Auto-switch interval: ${payload.auto_switch.interval_seconds}s`);
    }
    if (payload.auto_switch.event) {
      const event = payload.auto_switch.event;
      lines.push(
        `Last auto-switch: ${event.from_account || "-"} -> ${event.to_account || "-"} (${event.reason || "unknown"})`,
      );
    }
  }
  if (payload.last_action) {
    lines.push(`Session: ${formatActionLabel(payload.last_action)}`);
  }
  if (payload.last_action_at) {
    lines.push(`Last change: ${payload.last_action_at}`);
  }
  if (typeof payload.active_clients === "number") {
    lines.push(`Active clients: ${payload.active_clients}`);
  }
  if (typeof payload.idle_timeout_seconds === "number") {
    lines.push(`Idle timeout: ${payload.idle_timeout_seconds}s`);
  }
  if (payload.idle_shutdown_at) {
    lines.push(`Idle shutdown at: ${payload.idle_shutdown_at}`);
  }

  return lines.join("\n");
}

async function fetchJson(url, options = {}) {
  const response = await fetch(url, {
    ...options,
    headers: {
      "content-type": "application/json",
      ...(options.headers || {}),
    },
  });

  const body = await response.text();
  let payload = {};
  if (body) {
    payload = JSON.parse(body);
  }

  if (!response.ok) {
    const message = payload.error || `${response.status} ${response.statusText}`;
    throw new Error(message);
  }

  return payload;
}

async function getStateFromControlUrl(controlUrl) {
  return fetchJson(`${controlUrl}/v1/status`, { method: "GET" });
}

async function readStateFile(stateFile) {
  try {
    return await readJsonFile(stateFile);
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}

async function getLiveState(stateFile) {
  const state = await readStateFile(stateFile);
  if (!state || !state.control_url) {
    return null;
  }

  try {
    return await getStateFromControlUrl(state.control_url);
  } catch (_error) {
    return {
      ...state,
      running: false,
      ready: false,
      stale: true,
    };
  }
}

function isProcessAlive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) {
    return false;
  }

  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    if (error && error.code === "ESRCH") {
      return false;
    }
    return true;
  }
}

function bindPort(port) {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.once("error", reject);
    server.listen({ host: "127.0.0.1", port }, () => {
      const address = server.address();
      const boundPort =
        address && typeof address === "object" && address.port ? address.port : port;
      server.close((closeError) => {
        if (closeError) {
          reject(closeError);
          return;
        }
        resolve(boundPort);
      });
    });
  });
}

async function choosePort(preferredPort, allowFallback, reservedPorts = new Set()) {
  const requestedPort = toPositiveInteger(preferredPort, 0);

  if (requestedPort > 0 && !reservedPorts.has(requestedPort)) {
    try {
      return await bindPort(requestedPort);
    } catch (error) {
      if (!allowFallback || !["EADDRINUSE", "EACCES"].includes(error.code || "")) {
        throw error;
      }
    }
  }

  while (true) {
    const candidate = await bindPort(0);
    if (!reservedPorts.has(candidate)) {
      return candidate;
    }
  }
}

class AppServerController {
  constructor(options) {
    this.sessionSource = options.sessionSource;
    this.account = options.account;
    this.appPort = Number(options.appPort);
    this.controlPort = Number(options.controlPort);
    this.stateFile = options.stateFile;
    this.appLogFile = options.appLogFile;
    this.codexBin = options.codexBin || "codex";
    this.idleSeconds = toPositiveInteger(options.idleSeconds, 900);
    this.appUrl = `ws://127.0.0.1:${this.appPort}`;
    this.controlUrl = `http://127.0.0.1:${this.controlPort}`;
    this.pendingRequests = new Map();
    this.pendingNotifications = [];
    this.nextRequestId = 1;
    this.switchPromise = null;
    this.ready = false;
    this.shuttingDown = false;
    this.httpServer = null;
    this.ws = null;
    this.child = null;
    this.authMode = null;
    this.activeClients = new Map();
    this.lastIdleAt = Date.now();
    this.maintenanceTimer = null;
    this.autoSwitchEnabled = toBooleanFlag(options.autoSwitch);
    this.autoSwitchInterval = Math.max(1, toPositiveInteger(options.autoSwitchInterval, 15));
    this.autoSwitchTimer = null;
    this.autoSwitchEvent = null;
    this.lastAction = null;
    this.lastActionAt = null;
  }

  accountLabel(account) {
    if (this.sessionSource.kind === "accounts-dir") {
      return `account ${account}`;
    }
    return `session ${this.sessionSource.provider}/${account}`;
  }

  resolveAccountHome(account) {
    return resolveAccountHome(this.sessionSource, account);
  }

  async start() {
    ensureDirSync(path.dirname(this.stateFile));
    ensureDirSync(path.dirname(this.appLogFile));
    await this.startAppServer();
    await this.waitForAppServer();
    await this.connectController();
    await this.switchAccount(this.account);
    this.recordAction("started");
    await this.startControlServer();
    this.ready = true;
    await this.writeState();
    this.startMaintenanceLoop();
    this.startAutoSwitchLoop();
  }

  async startAppServer() {
    const appLogStream = fs.createWriteStream(this.appLogFile, {
      flags: "a",
      mode: 0o600,
    });
    const homeDir = this.resolveAccountHome(this.account);

    const childEnv = {
      ...process.env,
      CODEX_HOME: homeDir,
    };

    this.child = spawn(this.codexBin, ["app-server", "--listen", this.appUrl], {
      env: childEnv,
      stdio: ["ignore", "pipe", "pipe"],
    });

    this.child.stdout.pipe(appLogStream);
    this.child.stderr.pipe(appLogStream);

    this.child.on("exit", (code, signal) => {
      if (this.shuttingDown) {
        return;
      }
      console.error(
        `[codex-orbit-hot] app-server exited unexpectedly (code=${code ?? "null"} signal=${signal ?? "null"})`,
      );
      void this.shutdown(1);
    });
  }

  async waitForAppServer() {
    const deadline = Date.now() + 15000;
    let lastError = null;

    while (Date.now() < deadline) {
      try {
        const response = await fetch(`http://127.0.0.1:${this.appPort}/readyz`);
        if (response.ok) {
          return;
        }
        lastError = new Error(`readyz returned ${response.status}`);
      } catch (error) {
        lastError = error;
      }
      await sleep(200);
    }

    throw lastError || new Error("timed out waiting for app-server readiness");
  }

  async connectController() {
    this.ws = new WebSocket(this.appUrl);
    await new Promise((resolve, reject) => {
      this.ws.onopen = resolve;
      this.ws.onerror = reject;
    });

    this.ws.onmessage = (event) => {
      let message = null;
      try {
        message = JSON.parse(event.data);
      } catch (_error) {
        return;
      }
      this.handleMessage(message);
    };
    this.ws.onclose = () => {
      if (!this.shuttingDown) {
        console.error("[codex-orbit-hot] controller websocket closed unexpectedly");
        void this.shutdown(1);
      }
    };

    await this.request("initialize", {
      clientInfo: {
        name: "codex_orbit_hot",
        title: "Codex Orbit Hot Switch",
        version: "0.1.0",
      },
      capabilities: {
        experimentalApi: true,
      },
    });
    this.notify("initialized", {});
  }

  async startControlServer() {
    this.httpServer = http.createServer(async (req, res) => {
      try {
        if (req.method === "GET" && req.url === "/health") {
          this.writeJson(res, 200, { ok: true, ready: this.ready });
          return;
        }

        if (req.method === "GET" && req.url === "/v1/status") {
          if (this.autoSwitchEnabled) {
            try {
              await this.maybeAutoSwitch();
            } catch (_error) {
              // Background loop remains authoritative; status should still respond.
            }
          }
          this.writeJson(res, 200, this.statusPayload());
          return;
        }

        if (req.method === "POST" && req.url === "/v1/switch") {
          const body = await this.readJsonBody(req);
          const account = body.account;
          if (!account) {
            this.writeJson(res, 400, { error: "missing account" });
            return;
          }
          await this.switchAccount(account);
          await this.writeState();
          this.writeJson(res, 200, this.statusPayload());
          return;
        }

        if (req.method === "POST" && req.url === "/v1/auto-switch") {
          const body = await this.readJsonBody(req);
          const enabled = toBooleanFlag(body.enabled);
          const payload = await this.setAutoSwitch(enabled, body.interval);
          this.writeJson(res, 200, payload);
          return;
        }

        if (req.method === "POST" && req.url === "/v1/attach/start") {
          const body = await this.readJsonBody(req);
          this.registerClient(body.clientId, body.pid);
          await this.writeState();
          this.writeJson(res, 200, this.statusPayload());
          return;
        }

        if (req.method === "POST" && req.url === "/v1/attach/stop") {
          const body = await this.readJsonBody(req);
          this.unregisterClient(body.clientId);
          await this.writeState();
          this.writeJson(res, 200, this.statusPayload());
          return;
        }

        if (req.method === "POST" && req.url === "/v1/stop") {
          this.writeJson(res, 200, { stopping: true });
          setTimeout(() => {
            void this.shutdown(0);
          }, 0);
          return;
        }

        this.writeJson(res, 404, { error: "not found" });
      } catch (error) {
        this.writeJson(res, 500, { error: error.message || String(error) });
      }
    });

    await new Promise((resolve, reject) => {
      this.httpServer.once("error", reject);
      this.httpServer.listen(this.controlPort, "127.0.0.1", resolve);
    });
  }

  async switchAccount(account) {
    if (this.switchPromise) {
      throw new Error("a switch is already in progress");
    }

    this.switchPromise = (async () => {
      const previousAccount = this.account;
      const homeDir = this.resolveAccountHome(account);
      const tokens = loadChatgptTokens(homeDir, this.accountLabel(account));
      this.pendingNotifications = [];
      try {
        await this.request("account/logout", {});
      } catch (_error) {
        // Fresh servers may already be logged out. Login below is authoritative.
      }

      const completed = this.waitForNotification(
        (message) => message.method === "account/login/completed",
        10000,
      );
      const updated = this.waitForNotification(
        (message) =>
          message.method === "account/updated" &&
          message.params &&
          message.params.authMode,
        10000,
      );

      await this.request("account/login/start", {
        type: "chatgptAuthTokens",
        accessToken: tokens.accessToken,
        idToken: tokens.idToken,
        chatgptAccountId: tokens.chatgptAccountId,
      });

      const completedMessage = await completed;
      if (!completedMessage.params || completedMessage.params.success !== true) {
        const detail = completedMessage.params && completedMessage.params.error;
        throw new Error(detail || `login failed for ${account}`);
      }

      const updatedMessage = await updated;
      this.authMode = updatedMessage.params.authMode || null;
      this.account = account;
      if (previousAccount && previousAccount !== account) {
        this.recordAction("switched");
      }
      return this.statusPayload();
    })();

    try {
      return await this.switchPromise;
    } finally {
      this.switchPromise = null;
    }
  }

  registerClient(clientId, pid) {
    if (!clientId) {
      throw new Error("missing clientId");
    }

    const numericPid = Number(pid);
    this.activeClients.set(clientId, {
      pid: Number.isInteger(numericPid) && numericPid > 0 ? numericPid : null,
      attachedAt: Date.now(),
    });
    this.lastIdleAt = null;
  }

  unregisterClient(clientId) {
    if (!clientId) {
      throw new Error("missing clientId");
    }

    this.activeClients.delete(clientId);
    if (this.activeClients.size === 0) {
      this.lastIdleAt = Date.now();
    }
  }

  startMaintenanceLoop() {
    if (this.maintenanceTimer || this.idleSeconds <= 0) {
      return;
    }

    const intervalMs = Math.min(Math.max(this.idleSeconds * 250, 1000), 5000);
    this.maintenanceTimer = setInterval(() => {
      void this.runMaintenance();
    }, intervalMs);
    this.maintenanceTimer.unref();
  }

  recordAction(action) {
    this.lastAction = action;
    this.lastActionAt = new Date().toISOString();
  }

  availableAccounts() {
    return listSourceAccounts(this.sessionSource).filter((account) => {
      try {
        loadChatgptTokens(this.resolveAccountHome(account), this.accountLabel(account));
        return true;
      } catch (_error) {
        return false;
      }
    });
  }

  nextAutoSwitchTarget() {
    const accounts = this.availableAccounts();
    if (accounts.length <= 1 || !this.account) {
      return null;
    }

    const currentIndex = accounts.indexOf(this.account);
    const ordered =
      currentIndex >= 0
        ? [...accounts.slice(currentIndex + 1), ...accounts.slice(0, currentIndex)]
        : accounts;
    const candidates = ordered.filter((account) => account !== this.account);
    if (candidates.length === 0) {
      return null;
    }

    const quotaReady = candidates.filter((account) => {
      const quota = quotaStateForHome(this.resolveAccountHome(account));
      return quota.remaining != null && quota.remaining > 0 && !quota.deactivated;
    });
    if (quotaReady.length > 0) {
      return quotaReady[0];
    }

    const fallback = candidates.find((account) => !quotaStateForHome(this.resolveAccountHome(account)).deactivated);
    return fallback || candidates[0];
  }

  async maybeAutoSwitch() {
    if (!this.autoSwitchEnabled || !this.ready || !this.account) {
      return;
    }

    const currentQuota = quotaStateForHome(this.resolveAccountHome(this.account));
    if (!currentQuota.deactivated && (currentQuota.remaining == null || currentQuota.remaining > 0)) {
      return;
    }

    const target = this.nextAutoSwitchTarget();
    if (!target || target === this.account) {
      return;
    }

    const previousAccount = this.account;
    await this.switchAccount(target);
    this.autoSwitchEvent = {
      id: `${Date.now()}:${previousAccount}:${target}`,
      from_account: previousAccount,
      to_account: target,
      reason: currentQuota.deactivated ? "deactivated_workspace" : "quota_exhausted",
      created_at: new Date().toISOString(),
    };
    await this.writeState();
  }

  startAutoSwitchLoop() {
    if (this.autoSwitchTimer || !this.autoSwitchEnabled) {
      return;
    }

    this.autoSwitchTimer = setInterval(() => {
      void this.maybeAutoSwitch().catch(() => {});
    }, this.autoSwitchInterval * 1000);
    this.autoSwitchTimer.unref();
  }

  async setAutoSwitch(enabled, interval) {
    this.autoSwitchEnabled = Boolean(enabled);
    if (interval != null) {
      this.autoSwitchInterval = Math.max(1, toPositiveInteger(interval, this.autoSwitchInterval));
    }

    if (this.autoSwitchTimer) {
      clearInterval(this.autoSwitchTimer);
      this.autoSwitchTimer = null;
    }
    if (this.autoSwitchEnabled) {
      this.startAutoSwitchLoop();
      await this.maybeAutoSwitch();
    }
    await this.writeState();
    return this.statusPayload();
  }

  async runMaintenance() {
    if (this.shuttingDown) {
      return;
    }

    let changed = false;
    for (const [clientId, client] of this.activeClients.entries()) {
      if (client.pid && !isProcessAlive(client.pid)) {
        this.activeClients.delete(clientId);
        changed = true;
      }
    }

    if (this.activeClients.size === 0 && this.lastIdleAt == null) {
      this.lastIdleAt = Date.now();
      changed = true;
    }

    if (changed) {
      await this.writeState();
    }

    if (
      this.ready &&
      this.idleSeconds > 0 &&
      this.activeClients.size === 0 &&
      this.lastIdleAt != null &&
      Date.now() - this.lastIdleAt >= this.idleSeconds * 1000
    ) {
      await this.shutdown(0);
    }
  }

  handleMessage(message) {
    if (Object.prototype.hasOwnProperty.call(message, "id")) {
      const key = String(message.id);
      const pending = this.pendingRequests.get(key);
      if (pending) {
        this.pendingRequests.delete(key);
        pending.resolve(message);
        return;
      }
    }

    if (message.method === "account/chatgptAuthTokens/refresh") {
      void this.handleRefreshRequest(message);
      return;
    }

    if (message.method === "account/updated") {
      this.authMode = (message.params && message.params.authMode) || null;
    }

    this.pendingNotifications.push(message);
  }

  async handleRefreshRequest(message) {
    const requestId = message.id;
    if (!this.account) {
      this.send({
        id: requestId,
        error: {
          code: -32000,
          message: "no active account configured for refresh",
        },
      });
      return;
    }

    try {
      const tokens = loadChatgptTokens(
        this.resolveAccountHome(this.account),
        this.accountLabel(this.account),
      );
      this.send({
        id: requestId,
        result: {
          accessToken: tokens.accessToken,
          idToken: tokens.idToken,
        },
      });
    } catch (error) {
      this.send({
        id: requestId,
        error: {
          code: -32000,
          message: error.message || String(error),
        },
      });
    }
  }

  async request(method, params) {
    const id = `orbit-${this.nextRequestId++}`;
    const response = await new Promise((resolve, reject) => {
      this.pendingRequests.set(id, { resolve, reject });
      this.send({ method, id, params });
      setTimeout(() => {
        if (!this.pendingRequests.has(id)) {
          return;
        }
        this.pendingRequests.delete(id);
        reject(new Error(`timed out waiting for ${method}`));
      }, 10000);
    });

    if (response.error) {
      throw new Error(response.error.message || `request failed: ${method}`);
    }

    return response.result;
  }

  notify(method, params) {
    this.send({ method, params });
  }

  send(payload) {
    this.ws.send(JSON.stringify(payload));
  }

  waitForNotification(predicate, timeoutMs) {
    const deadline = Date.now() + timeoutMs;

    return new Promise((resolve, reject) => {
      const poll = () => {
        for (let idx = 0; idx < this.pendingNotifications.length; idx += 1) {
          const message = this.pendingNotifications[idx];
          if (predicate(message)) {
            this.pendingNotifications.splice(idx, 1);
            resolve(message);
            return;
          }
        }

        if (Date.now() >= deadline) {
          reject(new Error("timed out waiting for notification"));
          return;
        }

        setTimeout(poll, 50);
      };

      poll();
    });
  }

  statusPayload() {
    const idleShutdownAt =
      this.idleSeconds > 0 && this.activeClients.size === 0 && this.lastIdleAt != null
        ? new Date(this.lastIdleAt + this.idleSeconds * 1000).toISOString()
        : null;
    let activeHome = null;
    if (this.account) {
      try {
        activeHome = this.resolveAccountHome(this.account);
      } catch (_error) {
        activeHome = null;
      }
    }

    return {
      running: true,
      ready: this.ready,
      account: this.account,
      auth_mode: this.authMode,
      last_action: this.lastAction,
      last_action_at: this.lastActionAt,
      app_url: this.appUrl,
      control_url: this.controlUrl,
      app_port: this.appPort,
      control_port: this.controlPort,
      controller_pid: process.pid,
      app_server_pid: this.child ? this.child.pid : null,
      provider: this.sessionSource.provider,
      home: activeHome,
      auto_switch: {
        enabled: this.autoSwitchEnabled,
        interval_seconds: this.autoSwitchInterval,
        event: this.autoSwitchEvent,
      },
      active_clients: this.activeClients.size,
      idle_timeout_seconds: this.idleSeconds,
      idle_shutdown_at: idleShutdownAt,
      state_file: this.stateFile,
    };
  }

  writeJson(res, statusCode, payload) {
    res.statusCode = statusCode;
    res.setHeader("content-type", "application/json");
    res.end(`${JSON.stringify(payload)}\n`);
  }

  async readJsonBody(req) {
    const chunks = [];
    for await (const chunk of req) {
      chunks.push(chunk);
    }
    if (chunks.length === 0) {
      return {};
    }
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  }

  async writeState() {
    await writeJsonFile(this.stateFile, this.statusPayload());
  }

  async shutdown(exitCode) {
    if (this.shuttingDown) {
      return;
    }
    this.shuttingDown = true;

    if (this.maintenanceTimer) {
      clearInterval(this.maintenanceTimer);
      this.maintenanceTimer = null;
    }
    if (this.autoSwitchTimer) {
      clearInterval(this.autoSwitchTimer);
      this.autoSwitchTimer = null;
    }

    await removeFile(this.stateFile);

    if (this.httpServer) {
      await new Promise((resolve) => this.httpServer.close(resolve));
    }

    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.close();
    }

    if (this.child && this.child.exitCode === null) {
      this.child.kill("SIGTERM");
      const child = this.child;
      setTimeout(() => {
        if (child.exitCode === null) {
          child.kill("SIGKILL");
        }
      }, 3000);
    }

    setTimeout(() => process.exit(exitCode), 0);
  }
}

async function handleServe(options) {
  const required = ["account", "app-port", "control-port", "state-file", "app-log-file"];
  for (const key of required) {
    if (!options[key]) {
      throw new Error(`missing --${key}`);
    }
  }
  const sessionSource = buildSessionSource(options);

  const controller = new AppServerController({
    sessionSource,
    account: options.account,
    appPort: options["app-port"],
    controlPort: options["control-port"],
    stateFile: options["state-file"],
    appLogFile: options["app-log-file"],
    idleSeconds: options["idle-seconds"],
    codexBin: options["codex-bin"] || "codex",
    autoSwitch: options["auto-switch"],
    autoSwitchInterval: options["auto-switch-interval"],
  });

  process.on("SIGTERM", () => {
    void controller.shutdown(0);
  });
  process.on("SIGINT", () => {
    void controller.shutdown(0);
  });

  await controller.start();
}

async function handleStart(options) {
  const required = ["app-port", "control-port", "state-file", "log-file", "app-log-file"];
  for (const key of required) {
    if (!options[key]) {
      throw new Error(`missing --${key}`);
    }
  }
  const sessionSource = buildSessionSource(options);

  const desiredAccount = options.account || null;
  const current = await getLiveState(options["state-file"]);

  if (current && current.running) {
    if (options["auto-switch"] != null || options["auto-switch-interval"] != null) {
      const updated = await fetchJson(`${current.control_url}/v1/auto-switch`, {
        method: "POST",
        body: JSON.stringify({
          enabled: options["auto-switch"] == null ? current.auto_switch?.enabled : options["auto-switch"],
          interval: options["auto-switch-interval"],
        }),
      });
      if (desiredAccount && current.account !== desiredAccount) {
        const switched = await fetchJson(`${current.control_url}/v1/switch`, {
          method: "POST",
          body: JSON.stringify({ account: desiredAccount }),
        });
        console.log(`${JSON.stringify(switched)}\n`);
        return;
      }
      console.log(`${JSON.stringify({ ...updated, request_action: "reused" })}\n`);
      return;
    }
    if (desiredAccount && current.account !== desiredAccount) {
      const updated = await fetchJson(`${current.control_url}/v1/switch`, {
        method: "POST",
        body: JSON.stringify({ account: desiredAccount }),
      });
      console.log(`${JSON.stringify(updated)}\n`);
      return;
    }

    console.log(`${JSON.stringify({ ...current, request_action: "reused" })}\n`);
    return;
  }

  if (!desiredAccount) {
    throw new Error("missing account for a new hot session");
  }

  const allowPortFallback = toBooleanFlag(options["allow-port-fallback"]);
  const requestedAppPort = toPositiveInteger(options["app-port"], 0);
  const requestedControlPort = toPositiveInteger(options["control-port"], 0);
  const reservedPorts = new Set();
  const selectedAppPort = await choosePort(requestedAppPort, allowPortFallback, reservedPorts);
  reservedPorts.add(selectedAppPort);
  const selectedControlPort = await choosePort(
    requestedControlPort,
    allowPortFallback,
    reservedPorts,
  );

  const logFile = options["log-file"];
  ensureDirSync(path.dirname(logFile));
  const logFd = fs.openSync(logFile, "a", 0o600);

  const childArgs = [
    __filename,
    "serve",
    "--account",
    desiredAccount,
    "--app-port",
    String(selectedAppPort),
    "--control-port",
    String(selectedControlPort),
    "--state-file",
    options["state-file"],
    "--app-log-file",
    options["app-log-file"],
    "--idle-seconds",
    String(toPositiveInteger(options["idle-seconds"], 900)),
    "--auto-switch",
    options["auto-switch"] == null ? "0" : String(options["auto-switch"]),
    "--auto-switch-interval",
    String(toPositiveInteger(options["auto-switch-interval"], 15)),
  ];
  appendSessionSourceArgs(childArgs, sessionSource);
  if (options["codex-bin"]) {
    childArgs.push("--codex-bin", options["codex-bin"]);
  }

  const child = spawn(process.execPath, childArgs, {
    detached: true,
    stdio: ["ignore", logFd, logFd],
  });
  child.unref();
  fs.closeSync(logFd);

  const controlUrl = `http://127.0.0.1:${selectedControlPort}`;
  const deadline = Date.now() + 15000;
  let lastError = null;

  while (Date.now() < deadline) {
    try {
      const status = await getStateFromControlUrl(controlUrl);
      console.log(`${JSON.stringify({ ...status, request_action: "started" })}\n`);
      return;
    } catch (error) {
      lastError = error;
      await sleep(200);
    }
  }

  throw lastError || new Error("timed out waiting for hot controller");
}

async function handleStatus(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }

  const payload = (await getLiveState(options["state-file"])) || {
    running: false,
    ready: false,
  };

  if (options.json) {
    console.log(`${JSON.stringify(payload)}\n`);
    return;
  }

  console.log(stateToText(payload));
}

async function handleSwitch(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }
  if (!options.account) {
    throw new Error("missing --account");
  }

  const state = await readStateFile(options["state-file"]);
  if (!state || !state.control_url) {
    throw new Error("hot session is not running");
  }

  const payload = await fetchJson(`${state.control_url}/v1/switch`, {
    method: "POST",
    body: JSON.stringify({ account: options.account }),
  });
  console.log(`${JSON.stringify(payload)}\n`);
}

async function handleAutoSwitch(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }
  if (options.enabled == null) {
    throw new Error("missing --enabled");
  }

  const state = await readStateFile(options["state-file"]);
  if (!state || !state.control_url) {
    throw new Error("hot session is not running");
  }

  const payload = await fetchJson(`${state.control_url}/v1/auto-switch`, {
    method: "POST",
    body: JSON.stringify({
      enabled: options.enabled,
      interval: options.interval,
    }),
  });
  console.log(`${JSON.stringify(payload)}\n`);
}

async function handleStop(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }

  const state = await readStateFile(options["state-file"]);
  if (!state || !state.control_url) {
    await removeFile(options["state-file"]);
    console.log("stopped");
    return;
  }

  try {
    await fetchJson(`${state.control_url}/v1/stop`, {
      method: "POST",
      body: JSON.stringify({}),
    });
  } catch (_error) {
    if (state.controller_pid) {
      try {
        process.kill(state.controller_pid, "SIGTERM");
      } catch (_killError) {
        // Ignore stale pid failures.
      }
    }
  }

  await removeFile(options["state-file"]);
  console.log("stopped");
}

async function handleAttachStart(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }
  if (!options["client-id"]) {
    throw new Error("missing --client-id");
  }

  const state = await readStateFile(options["state-file"]);
  if (!state || !state.control_url) {
    throw new Error("hot session is not running");
  }

  const payload = await fetchJson(`${state.control_url}/v1/attach/start`, {
    method: "POST",
    body: JSON.stringify({
      clientId: options["client-id"],
      pid: options.pid ? Number(options.pid) : null,
    }),
  });
  console.log(`${JSON.stringify(payload)}\n`);
}

async function handleAttachStop(options) {
  if (!options["state-file"]) {
    throw new Error("missing --state-file");
  }
  if (!options["client-id"]) {
    throw new Error("missing --client-id");
  }

  const state = await readStateFile(options["state-file"]);
  if (!state || !state.control_url) {
    console.log("{}\n");
    return;
  }

  try {
    const payload = await fetchJson(`${state.control_url}/v1/attach/stop`, {
      method: "POST",
      body: JSON.stringify({
        clientId: options["client-id"],
      }),
    });
    console.log(`${JSON.stringify(payload)}\n`);
  } catch (_error) {
    console.log("{}\n");
  }
}

async function main() {
  const { command, options } = parseArgs(process.argv.slice(2));

  switch (command) {
    case "serve":
      await handleServe(options);
      break;
    case "start":
      await handleStart(options);
      break;
    case "status":
      await handleStatus(options);
      break;
    case "switch":
      await handleSwitch(options);
      break;
    case "autoswitch":
      await handleAutoSwitch(options);
      break;
    case "attach-start":
      await handleAttachStart(options);
      break;
    case "attach-stop":
      await handleAttachStop(options);
      break;
    case "stop":
      await handleStop(options);
      break;
    default:
      usage();
      process.exit(1);
  }
}

main().catch((error) => {
  console.error(`error: ${error.message || String(error)}`);
  process.exit(1);
});
