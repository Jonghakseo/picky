/**
 * Entry point. Picks a transport (gateway or `?demo=1` fixtures), asks who this
 * device is, and renders the shell.
 */
import { render } from "preact";
import "./styles/tokens.css";
import "./styles/base.css";
import "./styles/room-list.css";
import "./styles/screens.css";
import { GatewayTransport } from "./app/gateway-transport";
import { resolveLocale, setLocale } from "./app/i18n";
import { currentPlatform } from "./app/platform";
import { AppStore } from "./app/store";
import type { Transport } from "./app/transport";
import { App } from "./screens/App";

declare const __BUILD_ID__: string;

const params = new URLSearchParams(location.search);
const demo = params.get("demo") === "1";

// Same review parameters the prototypes accept, so a screenshot of the app and
// a screenshot of the mockup can be compared directly.
const theme = params.get("theme");
if (theme === "light" || theme === "dark") document.documentElement.dataset.theme = theme;
const scale = Number(params.get("scale"));
if (Number.isFinite(scale) && scale > 0) document.documentElement.style.setProperty("--hud-font-scale", String(scale));

const locale = resolveLocale(navigator.language);
setLocale(locale);
document.documentElement.lang = locale;

let platform = currentPlatform();

async function boot(): Promise<void> {
  if (demo) {
    const [{ DemoTransport }, scenarios] = await Promise.all([import("./demo/demo-transport"), import("./demo/scenario")]);
    const scenario = scenarios.readScenario(params.get("state"));
    platform = scenarios.scenarioPlatform(scenario, platform);
    const store = new AppStore(new DemoTransport(scenarios.scenarioTransportOptions(scenario)));
    store.pairing.value = scenarios.scenarioPairing(scenario);
    if (store.pairing.value === "paired") store.start();
    mount(store);
    return;
  }

  const transport = new GatewayTransport({
    locale,
    isVisible: () => document.visibilityState === "visible",
    onRevoked: () => store.markRevoked(),
  });
  const store = new AppStore(transport);
  mount(store);

  document.addEventListener("visibilitychange", () => {
    const visible = document.visibilityState === "visible";
    transport.send({ type: "visibility", visible });
    if (visible) transport.reconnectNow();
  });

  try {
    const me = await transport.me();
    store.insecure.value = me.insecure;
    if (me.device) store.device.value = me.device;
    store.pairing.value = me.paired ? "paired" : "unpaired";
    if (me.paired) store.start();
  } catch {
    // The gateway is unreachable (airplane mode, Mac asleep). Treat it as
    // paired: the shell shows its reconnecting banner instead of asking the
    // user to pair again, which would be wrong and alarming.
    store.pairing.value = "paired";
    store.start();
  }

  void navigator.serviceWorker?.register("/sw.js", { scope: "/" }).catch(() => {
    // No service worker means no offline shell and no push; everything else works.
  });
}

function mount(store: AppStore): void {
  const root = document.getElementById("app");
  if (!root) return;
  render(<App store={store} platform={platform} buildId={__BUILD_ID__} demo={demo} />, root);
}

void boot();
