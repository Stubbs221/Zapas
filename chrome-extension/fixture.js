document.getElementById("loaded").textContent = `Страница загружена: ${new Date().toISOString()}`;
globalThis.zapasFixtureLoadID = crypto.randomUUID();
// A modest, touched 8 MiB allocation makes the fixture observable; it is not a RAM measurement.
const allocation = new Uint8Array(8 * 1024 * 1024);
for (let index = 0; index < allocation.length; index += 4096) allocation[index] = 1;
globalThis.zapasFixtureAllocation = allocation;
let audio = null;
let oscillator = null;
document.getElementById("audio").addEventListener("click", async () => {
  if (audio) return;
  audio = new AudioContext(); await audio.resume();
  oscillator = audio.createOscillator(); const gain = audio.createGain(); gain.gain.value = 0.025;
  oscillator.connect(gain); gain.connect(audio.destination); oscillator.start();
  document.getElementById("audio-state").textContent = "Тестовый звук включён";
});
document.getElementById("stop").addEventListener("click", async () => {
  oscillator?.stop(); await audio?.close(); audio = null; oscillator = null;
  document.getElementById("audio-state").textContent = "Звук остановлен";
});
