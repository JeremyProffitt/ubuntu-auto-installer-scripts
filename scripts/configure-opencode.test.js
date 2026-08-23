const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")

const { configureOpenCode } = require("./configure-opencode")

function fixture(t) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-config-test-"))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const configFile = path.join(directory, "opencode.json")
  const agentRulesFile = path.join(directory, "source-AGENTS.md")
  fs.writeFileSync(agentRulesFile, "# Portable rules\n")
  return { directory, configFile, agentRulesFile }
}

test("creates a GB10 OpenCode configuration", (t) => {
  const { directory, configFile, agentRulesFile } = fixture(t)

  configureOpenCode(
    configFile,
    "http://192.168.40.250:11434/v1",
    "qwen-coder-yarn:latest",
    "524288",
    "32768",
    "900000",
    agentRulesFile
  )

  const config = JSON.parse(fs.readFileSync(configFile, "utf8"))
  assert.equal(config.model, "gb10/qwen-coder-yarn:latest")
  assert.equal(config.small_model, "gb10/qwen-coder-yarn:latest")
  assert.equal(config.provider.gb10.options.baseURL, "http://192.168.40.250:11434/v1")
  assert.equal(config.provider.gb10.options.timeout, 900000)
  assert.ok(config.provider.gb10.models["qwen-coder-yarn:latest"])
  assert.equal(config.provider.gb10.models["qwen-coder-yarn:latest"].tool_call, true)
  assert.deepEqual(config.provider.gb10.models["qwen-coder-yarn:latest"].limit, {
    context: 524288,
    output: 32768
  })
  assert.deepEqual(config.provider.gb10.models["qwen-coder-yarn:latest"].modalities, {
    input: ["text"],
    output: ["text"]
  })
  assert.equal(fs.readFileSync(path.join(directory, "AGENTS.md"), "utf8"), "# Portable rules\n")
})

test("preserves existing settings and keeps the first backup", (t) => {
  const { directory, configFile, agentRulesFile } = fixture(t)
  const original = JSON.stringify({ mcp: { filesystem: { enabled: true } } })
  const originalRules = "# Original rules\n"
  fs.writeFileSync(configFile, original)
  fs.writeFileSync(path.join(directory, "AGENTS.md"), originalRules)

  configureOpenCode(configFile, "http://192.168.40.250:11434/v1", "qwen-coder-yarn:latest", 524288, 32768, 900000, agentRulesFile)
  fs.writeFileSync(agentRulesFile, "# Updated portable rules\n")
  configureOpenCode(configFile, "http://192.168.40.251:11434/v1", "qwen-coder-next", 262144, 16384, 600000, agentRulesFile)

  const config = JSON.parse(fs.readFileSync(configFile, "utf8"))
  assert.equal(config.mcp.filesystem.enabled, true)
  assert.equal(config.model, "gb10/qwen-coder-next")
  assert.equal(fs.readFileSync(`${configFile}.pre-gb10`, "utf8"), original)
  assert.equal(fs.readFileSync(path.join(directory, "AGENTS.md.pre-gb10"), "utf8"), originalRules)
  assert.equal(fs.readFileSync(path.join(directory, "AGENTS.md"), "utf8"), "# Updated portable rules\n")
})

test("rejects unsafe endpoint and model values", () => {
  assert.throws(
    () => configureOpenCode("unused", "http://gb10/v1?bad=true", "qwen-coder-yarn:latest", 524288, 32768, 900000, "unused"),
    /Invalid GB10 base URL/
  )
  assert.throws(
    () => configureOpenCode("unused", "http://gb10:11434/v1", "bad model", 524288, 32768, 900000, "unused"),
    /Invalid GB10 model/
  )
  assert.throws(
    () => configureOpenCode("unused", "http://gb10:11434/v1", "model", 524288, 524288, 900000, "unused"),
    /output limit must be smaller/
  )
})
