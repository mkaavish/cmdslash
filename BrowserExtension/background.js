// CmdSlash Browser Bridge — background service worker.
//
// Talks to CmdSlash.app's local BrowserBridgeServer (Docs/PLANNING.md §23) over a plain
// localhost HTTP long-poll, not Chrome's Native Messaging mechanism — see BrowserBridgeServer.swift
// for why. Protocol: GET /poll holds the connection open until a command arrives (or ~20s
// elapses, in which case we just poll again); POST /result reports back what happened.
//
// The polling loop below is deliberately self-healing rather than relying on a persistent
// connection: Manifest V3 service workers can be terminated and respawned by Chrome at any time.
// Because pollLoop() runs unconditionally at the top level of this file, it restarts automatically
// every time the service worker re-executes for any reason — but "for any reason" isn't a real
// guarantee: if Chrome decides there's nothing that needs the worker (no alarm, no pending event),
// it can just stay terminated indefinitely, silently breaking the bridge until the extension is
// manually reloaded. The chrome.alarms registration below forces a periodic wake regardless.

const SERVER_BASE = "http://127.0.0.1:57130";

// Guards against a duplicate concurrent loop: if the worker never actually died, the alarm still
// fires on schedule, but pollLoop() below is already running — without this flag, each alarm would
// start a second/third/... loop all hitting /poll at once.
let pollLoopRunning = false;

async function pollLoop() {
  if (pollLoopRunning) return;
  pollLoopRunning = true;
  try {
    for (;;) {
      try {
        const response = await fetch(`${SERVER_BASE}/poll`);
        const command = await response.json();
        if (command && command.id) {
          await handleCommand(command);
        }
      } catch (error) {
        // CmdSlash isn't running, or the port isn't reachable yet — back off briefly rather than
        // spinning in a tight failure loop against a server that isn't there.
        await new Promise((resolve) => setTimeout(resolve, 3000));
      }
    }
  } finally {
    pollLoopRunning = false;
  }
}

// Chrome's minimum period for a repeating alarm is 1 minute — frequent enough that the bridge
// recovers quickly after an idle-triggered termination, without registering something so frequent
// Chrome would throttle it.
chrome.alarms.create("keepPolling", { periodInMinutes: 1 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "keepPolling") {
    pollLoop();
  }
});

async function handleCommand(command) {
  try {
    const data = await executeAction(command.action, command.params || {});
    await postResult(command.id, true, data, null);
  } catch (error) {
    await postResult(command.id, false, null, String((error && error.message) || error));
  }
}

async function postResult(id, success, data, error) {
  await fetch(`${SERVER_BASE}/result`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ id, success, data, error }),
  });
}

async function getActiveTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab || !tab.id) {
    throw new Error("No active browser tab found.");
  }
  return tab;
}

async function executeAction(action, params) {
  if (action === "navigate") {
    const tab = await getActiveTab();
    await chrome.tabs.update(tab.id, { url: params.url });
    return await waitForTabLoad(tab.id);
  }

  if (action === "get_page_text") {
    const tab = await getActiveTab();
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => {
        // Links, not just visible text — without these the agent can see the WORD "Pricing" on
        // the page but has no URL to actually navigate to if what it needs isn't on this page.
        const seen = new Set();
        const links = Array.from(document.querySelectorAll("a[href]"))
          .map((a) => ({ text: a.innerText.trim().replace(/\s+/g, " "), href: a.href }))
          .filter((l) => l.text.length > 0 && l.text.length < 60 && l.href.startsWith("http"))
          .filter((l) => {
            const key = l.href + "|" + l.text;
            if (seen.has(key)) return false;
            seen.add(key);
            return true;
          })
          .slice(0, 40);

        return {
          url: document.location.href,
          title: document.title,
          text: document.body ? document.body.innerText : "",
          links,
        };
      },
    });
    return result;
  }

  if (action === "click") {
    const tab = await getActiveTab();
    const [{ result }] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      args: [params.text || ""],
      func: (searchText) => {
        const normalizedTarget = searchText.trim().toLowerCase();
        if (!normalizedTarget) {
          return { clicked: false, reason: "No text given to match." };
        }

        const candidates = Array.from(
          document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [onclick]')
        ).filter((el) => {
          const style = window.getComputedStyle(el);
          return style.display !== "none" && style.visibility !== "hidden" && el.offsetParent !== null;
        });

        const textOf = (el) =>
          (el.innerText || el.value || el.getAttribute("aria-label") || el.getAttribute("title") || "").trim();

        // Prefer an exact (case-insensitive) match over the first substring match — a page often
        // has both "Cart" and "Add to Cart", and the model usually named the one it actually meant.
        let target = candidates.find((el) => textOf(el).toLowerCase() === normalizedTarget);
        if (!target) {
          target = candidates.find((el) => textOf(el).toLowerCase().includes(normalizedTarget));
        }
        if (!target) {
          return { clicked: false, reason: `No visible clickable element matching "${searchText}" was found.` };
        }

        target.scrollIntoView({ block: "center" });
        target.click();
        return { clicked: true, matchedText: textOf(target) };
      },
    });
    if (!result || !result.clicked) {
      throw new Error((result && result.reason) || "Click failed.");
    }
    // Give the page a moment to react (navigation, DOM update) before the caller reads it again.
    await new Promise((resolve) => setTimeout(resolve, 300));
    return { matchedText: result.matchedText };
  }

  throw new Error(`Unknown action: ${action}`);
}

function waitForTabLoad(tabId, timeoutMs = 15000) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      chrome.tabs.onUpdated.removeListener(listener);
      reject(new Error("Timed out waiting for the page to load."));
    }, timeoutMs);

    function listener(updatedTabId, changeInfo, tab) {
      if (updatedTabId === tabId && changeInfo.status === "complete") {
        clearTimeout(timeout);
        chrome.tabs.onUpdated.removeListener(listener);
        resolve(tab.url || "");
      }
    }
    chrome.tabs.onUpdated.addListener(listener);
  });
}

pollLoop();
