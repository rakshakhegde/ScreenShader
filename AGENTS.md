# Coding Standards & Guidelines

## 1. Minimal Surgical Changes
- **Change only what was asked for:** Never add unrequested features, speculative defensive layers, or duplicate fallback handlers.
- **Search before creating:** Always inspect existing classes, models, and configuration properties to reuse existing state before introducing new variables or methods.
- **No duplicate responder handlers:** Let the primary focused view handle its events; do not duplicate event-handling logic across multiple parent/controller levels unless specifically requested.

## 2. Platform & Deployment Targets
- **Respect deployment target:** Always check `MACOSX_DEPLOYMENT_TARGET` (macOS 14.0 for this project) before writing `#available` checks. Do not wrap APIs in `#available` guards if they are already guaranteed by the minimum deployment target.

## 3. Clarity & Readability
- **No magic numbers:** Do not use raw numeric keycodes or magic flags. Use named constants (e.g. `kVK_Space`, `kVK_Return`) or expressive properties (`charactersIgnoringModifiers == " "`).
