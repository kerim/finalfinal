#!/usr/bin/env osascript -l JavaScript

// Find and approve any MCP agent access dialogs in Xcode.

function run() {

var se = Application("System Events");

try { se.processes.byName("Xcode").name(); } catch (e) { return "Xcode not running."; }

var count = 0;

var windows = se.processes.byName("Xcode").windows();

for (var i = 0; i < windows.length; i++) {

try {

var w = windows[i];

if (w.subrole() !== "AXDialog") continue;

if (!w.staticTexts().some(function(t) { return (t.value() || "").indexOf("to access Xcode?") !== -1; })) continue;

w.buttons.byName("Allow").click();

count++;

} catch (e) {}

}

return count ? "Allowed " + count + " MCP connection(s)." : "No MCP dialogs found.";

}
