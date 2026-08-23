package main

import (
	"strings"
	"testing"
)

func TestGenerateConfigEnvIncludesOpenCodeSettings(t *testing.T) {
	config := &Config{
		Username:          "admin",
		Hostname:          "ubuntu-test",
		InstallOpenCode:   true,
		OpenCodeGB10URL:   "http://192.168.40.250:11434/v1",
		OpenCodeGB10Model: "qwen-coder-yarn:latest",
	}

	got := generateConfigEnv(config)
	wantLines := []string{
		"INSTALL_OPENCODE=true",
		"OPENCODE_GB10_BASE_URL=http://192.168.40.250:11434/v1",
		"OPENCODE_GB10_MODEL=qwen-coder-yarn:latest",
	}

	for _, want := range wantLines {
		if !strings.Contains(got, want+"\n") {
			t.Errorf("generateConfigEnv() missing %q", want)
		}
	}
}
