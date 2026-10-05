// Entry point. Scaffold only; the web foundation worker replaces the body.
import { render } from "preact";
import "./styles/tokens.css";
import "./styles/base.css";

function App() {
  return <main class="app-boot">Picky</main>;
}

render(<App />, document.getElementById("app")!);
