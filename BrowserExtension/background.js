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
// every time the service worker re-executes for any reason — no separate "reconnect" logic needed.

const SERVER_BASE = "http://127.0.0.1:57130";

async function pollLoop() {
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
}

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
      func: () => ({
        url: document.location.href,
        title: document.title,
        text: document.body ? document.body.innerText : "",
      }),
    });
    return result;
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
