# ShopLens — C4 Architecture Diagrams

C4 model diagrams for the ML-Kit → Gemini → Lens product-identification pipeline.

| File | Level | What it shows |
|------|-------|---------------|
| [c1-system-context.md](c1-system-context.md) | C1 Context | ShopLens as a black box — users and external systems |
| [c2-container.md](c2-container.md) | C2 Container | Deployable units: mobile app, AI Analyzer, Firebase, GCS, etc. |
| [c3-component.md](c3-component.md) | C3 Component | Internals of the AI Analyzer service — routes, functions, cache |
| [c4-code.md](c4-code.md) | C4 Code | Sequence diagram — exact call chain for Tap and Scan-All paths |

All diagrams use [Mermaid](https://mermaid.js.org/) and render natively in GitHub.
