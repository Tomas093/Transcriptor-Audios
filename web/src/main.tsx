import { Component, StrictMode, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import App from "./App";
import "./styles.css";
import "./styles/lab.css";
import "./styles/skins.css";
import { applyStyle, currentStyle } from "./theme";

class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false };
  static getDerivedStateFromError() {
    return { failed: true };
  }
  componentDidCatch(error: unknown) {
    console.error(error);
  }
  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div className="crash" role="alert">
        <h1>Algo salió mal</h1>
        <p>Tus sesiones y audios están a salvo en el disco. Recarga la página para continuar.</p>
        <button type="button" className="btn btn-primary" onClick={() => location.reload()}>
          Recargar
        </button>
      </div>
    );
  }
}

applyStyle(currentStyle()); // antes del primer render, para evitar parpadeo

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <Boundary>
      <App />
    </Boundary>
  </StrictMode>,
);
