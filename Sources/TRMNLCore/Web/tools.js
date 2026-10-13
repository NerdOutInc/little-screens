const status = document.getElementById("tool-status");
const reference = document.getElementById("tool-reference");

try {
  const response = await fetch("/api/tools", { credentials: "same-origin" });
  if (!response.ok) throw new Error("Could not load tool contracts. Reload this Help page.");
  const { tools } = await response.json();
  reference.replaceChildren();
  for (const tool of tools) {
    const term = document.createElement("dt");
    const name = document.createElement("code");
    name.textContent = tool.name;
    term.append(name);
    const detail = document.createElement("dd");
    const description = document.createElement("p");
    description.textContent = tool.description;
    const fields = document.createElement("p");
    fields.textContent = "Arguments: " + (Object.entries(tool.inputSchema.properties)
      .map(([key, value]) => `${key} (${value.type})`).join(", ") || "none");
    detail.append(description, fields);
    reference.append(term, detail);
  }

  if (typeof document.modelContext?.registerTool !== "function") {
    status.textContent = "Help is ready. WebMCP is unavailable in this browser. Open this URL in Codex’s built-in browser to use site tools.";
  } else {
    for (const tool of tools) {
      await document.modelContext.registerTool({
        ...tool,
        execute: async (input) => {
          const result = await fetch(`/api/tools/${tool.name}`, {
            method: "POST",
            credentials: "same-origin",
            headers: { "Content-Type": "application/json", "X-AI-TRMNL": "1" },
            body: JSON.stringify(input),
          });
          const payload = await result.json();
          if (!result.ok) throw new Error(JSON.stringify(payload));
          return payload;
        },
      });
    }
    status.textContent = `${tools.length} WebMCP tools registered. Codex can now check server status and help pair a device.`;
  }
} catch (error) {
  status.textContent = `Agent tools could not start: ${error.message}`;
}
