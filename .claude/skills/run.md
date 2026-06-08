---
name: run
description: Start the cfst-web-panel development server and open it in a browser to verify the UI is working.
---

Start the cfst-web-panel development server. The default port is 3088 (falls back to 3089).

Steps:
1. Check that `./cfst` binary exists and has execute permissions (`chmod +x cfst` if needed).
2. Run `node server.js` (or `npm start`) in the project root.
3. Open `http://localhost:3088` in the browser.
4. Verify the four tabs load: 速测 (Test), 收藏 (Favorites), DNS, 设置 (Settings).
5. Report the actual URL the server is listening on (check terminal output for the port).

If the binary is missing, inform the user they need to download `cfst` from the upstream CloudflareSpeedTest releases and place it in the project root.
