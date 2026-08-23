const assert = require("node:assert/strict")
const fs = require("node:fs")
const os = require("node:os")
const path = require("node:path")
const test = require("node:test")

const { configureOpenCode } = require("./configure-opencode")

test("creates a GB10 OpenCode configuration", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-config-test-"))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const configFile = path.join(directory, "opencode.json")

  configureOpenCode(configFile, "http://192.168.40.250:11434/v1", "qwen-coder-yarn:latest")

  const config = JSON.parse(fs.readFileSync(configFile, "utf8"))
  assert.equal(config.model, "gb10/qwen-coder-yarn:latest")
  assert.equal(config.small_model, "gb10/qwen-coder-yarn:latest")
  assert.equal(config.provider.gb10.options.baseURL, "http://192.168.40.250:11434/v1")
  assert.ok(config.provider.gb10.models["qwen-coder-yarn:latest"])
})

test("preserves existing settings and keeps the first backup", (t) => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "opencode-config-test-"))
  t.after(() => fs.rmSync(directory, { recursive: true, force: true }))
  const configFile = path.join(directory, "opencode.json")
  const original = JSON.stringify({ mcp: { filesystem: { enabled: true } } })
  fs.writeFileSync(configFile, original)

  configureOpenCode(configFile, "http://192.168.40.250:11434/v1", "qwen-coder-yarn:latest")
  configureOpenCode(configFile, "http://192.168.40.251:11434/v1", "qwen-coder-next")

  const config = JSON.parse(fs.readFileSync(configFile, "utf8"))
  assert.equal(config.mcp.filesystem.enabled, true)
  assert.equal(config.model, "gb10/qwen-coder-next")
  assert.equal(fs.readFileSync(`${configFile}.pre-gb10`, "utf8"), original)
})

test("rejects unsafe endpoint and model values", () => {
  assert.throws(
    () => configureOpenCode("unused", "http://gb10/v1?bad=true", "qwen-coder-yarn:latest"),
    /Invalid GB10 base URL/
  )
  assert.throws(
    () => configureOpenCode("unused", "http://gb10:11434/v1", "bad model"),
    /Invalid GB10 model/
  )
})
