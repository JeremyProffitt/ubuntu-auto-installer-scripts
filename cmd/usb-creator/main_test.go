package main

import (
	"strings"
	"testing"
)

func TestGenerateConfigEnvIncludesOpenCodeSettings(t *testing.T) {
	config := &Config{
		Username:            "admin",
		Hostname:            "ubuntu-test",
		InstallOpenCode:     true,
		OpenCodeGB10URL:     "http://192.168.40.250:11434/v1",
		OpenCodeGB10Model:   "qwen-coder-yarn:latest",
		OpenCodeGB10Context: 524288,
		OpenCodeGB10Output:  32768,
		OpenCodeGB10Timeout: 900000,
	}

	got := generateConfigEnv(config)
	wantLines := []string{
		"INSTALL_OPENCODE=true",
		"OPENCODE_GB10_BASE_URL=http://192.168.40.250:11434/v1",
		"OPENCODE_GB10_MODEL=qwen-coder-yarn:latest",
		"OPENCODE_GB10_CONTEXT=524288",
		"OPENCODE_GB10_OUTPUT=32768",
		"OPENCODE_GB10_TIMEOUT_MS=900000",
	}

	for _, want := range wantLines {
		if !strings.Contains(got, want+"\n") {
			t.Errorf("generateConfigEnv() missing %q", want)
		}
	}
}

func TestGetPositiveIntEnv(t *testing.T) {
	got, err := getPositiveIntEnv(map[string]string{"VALUE": "42"}, "VALUE", 1)
	if err != nil || got != 42 {
		t.Fatalf("getPositiveIntEnv() = %d, %v; want 42, nil", got, err)
	}

	if _, err := getPositiveIntEnv(map[string]string{"VALUE": "0"}, "VALUE", 1); err == nil {
		t.Fatal("getPositiveIntEnv() accepted zero")
	}
}
