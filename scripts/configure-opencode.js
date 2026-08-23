#!/usr/bin/env node

const fs = require("fs")
const path = require("path")

const URL_PATTERN = /^https?:\/\/[A-Za-z0-9._:-]+(?:\/[A-Za-z0-9._~:/-]*)?$/
const MODEL_PATTERN = /^[A-Za-z0-9][A-Za-z0-9._:/-]*$/

function positiveInteger(value, name) {
  if (!/^\d+$/.test(String(value)) || Number(value) < 1 || !Number.isSafeInteger(Number(value))) {
    throw new Error(`Invalid ${name}: ${value}`)
  }
  return Number(value)
}

function installAgentRules(configFile, agentRulesFile) {
  if (!fs.existsSync(agentRulesFile)) {
    throw new Error(`Global agent rules file not found: ${agentRulesFile}`)
  }

  const targetFile = path.join(path.dirname(configFile), "AGENTS.md")
  if (fs.existsSync(targetFile)) {
    const backupFile = `${targetFile}.pre-gb10`
    if (!fs.existsSync(backupFile)) {
      fs.copyFileSync(targetFile, backupFile)
      fs.chmodSync(backupFile, 0o600)
    }
  }

  const temporaryFile = `${targetFile}.${process.pid}.tmp`
  fs.copyFileSync(agentRulesFile, temporaryFile)
  fs.chmodSync(temporaryFile, 0o600)
  fs.renameSync(temporaryFile, targetFile)
}

function configureOpenCode(configFile, baseURL, model, contextLimit, outputLimit, timeout, agentRulesFile) {
  if (!URL_PATTERN.test(baseURL)) {
    throw new Error(`Invalid GB10 base URL: ${baseURL}`)
  }
  if (!MODEL_PATTERN.test(model)) {
    throw new Error(`Invalid GB10 model: ${model}`)
  }

  const context = positiveInteger(contextLimit, "GB10 context limit")
  const output = positiveInteger(outputLimit, "GB10 output limit")
  const requestTimeout = positiveInteger(timeout, "GB10 request timeout")
  if (output >= context) {
    throw new Error("GB10 output limit must be smaller than the context limit")
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
      apiKey: "ollama",
      timeout: requestTimeout
    },
    models: {
      [model]: {
        name: `GB10 ${model}`,
        attachment: false,
        reasoning: false,
        tool_call: true,
        limit: {
          context,
          output
        },
        modalities: {
          input: ["text"],
          output: ["text"]
        }
      }
    }
  }
  config.model = `gb10/${model}`
  config.small_model = `gb10/${model}`

  const temporaryFile = `${configFile}.${process.pid}.tmp`
  fs.writeFileSync(temporaryFile, `${JSON.stringify(config, null, 2)}\n`, { mode: 0o600 })
  fs.renameSync(temporaryFile, configFile)
  fs.chmodSync(configFile, 0o600)
  installAgentRules(configFile, agentRulesFile)
}

if (require.main === module) {
  const [configFile, baseURL, model, contextLimit, outputLimit, timeout, agentRulesFile] = process.argv.slice(2)
  if (!configFile || !baseURL || !model || !contextLimit || !outputLimit || !timeout || !agentRulesFile) {
    console.error("Usage: configure-opencode.js <config-file> <base-url> <model> <context-limit> <output-limit> <timeout-ms> <agent-rules-file>")
    process.exit(2)
  }

  try {
    configureOpenCode(configFile, baseURL, model, contextLimit, outputLimit, timeout, agentRulesFile)
  } catch (error) {
    console.error(`OpenCode configuration failed: ${error.message}`)
    process.exit(1)
  }
}

module.exports = { configureOpenCode }
