import { exclusion } from "./policy.mjs";
async function command(type) {
  const reply = await chrome.runtime.sendMessage({ type });
  if (!reply?.ok) throw new Error(reply?.issue ?? "Нет ответа service worker");
  return reply;
}
async function refresh() {
  try {
    const reply = await command("status");
    document.querySelector("#status").textContent = reply.connected ? `Подключено. Session: ${reply.sessionID}` : `Отключено. ${reply.lastIssue ?? ""}`;
    document.querySelector("#result").textContent = reply.lastResult ? JSON.stringify(reply.lastResult, null, 2) : "";
    const body = document.querySelector("#tabs"); body.replaceChildren();
    for (const tab of reply.tabs) {
      const row = document.createElement("tr");
      for (const value of [tab.id, tab.title, tab.discarded ? "Выгружена" : "Загружена", exclusion(tab) ?? "Можно выбрать тестовую вкладку"]) {
        const cell = document.createElement("td"); cell.textContent = String(value); row.append(cell);
      }
      body.append(row);
    }
  } catch (error) { document.querySelector("#status").textContent = error.message; }
}
for (const [id, type] of [["connect", "connect"], ["disconnect", "disconnect"], ["fixture", "create-fixture"]]) {
  document.getElementById(id).addEventListener("click", async () => {
    try { await command(type); await refresh(); }
    catch (error) { document.querySelector("#status").textContent = error.message; }
  });
}
document.getElementById("refresh").addEventListener("click", refresh);
refresh();
