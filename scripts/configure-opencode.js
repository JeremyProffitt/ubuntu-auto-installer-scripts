#!/usr/bin/env node

const fs = require("fs")

const URL_PATTERN = /^https?:\/\/[A-Za-z0-9._:-]+(?:\/[A-Za-z0-9._~:/-]*)?$/
const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]*$/

function configureOpenCode(configFile, baseURL, model) {
  if (!URL_PATTERN.test(baseURL)) {
    throw new Error(`Invalid GB10 base URL: ${baseURL}`)
  }
  if (!MODEL_PATTERN.test(model)) {
    throw new Error(`Invalid GB10 model: ${model}`)
  }

  let config = { "$schema": "https://opencode.ai/config.json" }

  if (fs.existsSync(configFile)) {
    config = JSON.parse(fs.readFileSync(configFile, "utf8"))

    const backupFile = `${configFile}.pre-gb10`
    if (!fs.existsSync(backupFile)) {
      fs.copyFileSync(configFile, backupFile)
      fs.chmodSync(backupFile, 0o600)
    }
  }

  config.$schema ||= "https://opencode.ai/config.json"
  config.provider ||= {}
  config.provider.gb10 = {
    npm: "@ai-sdk/openai-compatible",
    name: "GB10 Qwen (Ollama)",
    options: {
      baseURL,
      apiKey: "ollama"
    },
    models: {
      [model]: {
        name: `GB10 ${model}`
      }
    }
  }
  config.model = `gb10/${model}`
  config.small_model = `gb10/${model}`

  const temporaryFile = `${configFile}.${process.pid}.tmp`
  fs.writeFileSync(temporaryFile, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 })
  fs.renameSync(temporaryFile, configFile)
  fs.chmodSync(configFile, 0o600)
}

if (require.main === module) {
  const [configFile, baseURL, model] = process.argv.slice(2)
  if (!configFile || !baseURL || !model) {
    console.error("Usage: configure-opencode.js <config-file> <base-url> <model>")
    process.exit(2)
  }

  try {
    configureOpenCode(configFile, baseURL, model)
  } catch (error) {
    console.error(`OpenCode configuration failed: ${error.message}`)
    process.exit(1)
  }
}

module.exports = { configureOpenCode }
