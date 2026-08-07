// internal/training/model_manager.go
// Model download, discovery, and validation for GRPO training.
package training

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// SupportedModels lists known models that work with GRPO training.
var SupportedModels = []ModelInfo{
	{Name: "qwen3:8b", Size: "4.9 GB", Params: "8B", Quant: "Q4_K_M", Recommended: true},
	{Name: "qwen3:4b", Size: "2.6 GB", Params: "4B", Quant: "Q4_K_M", Recommended: false},
	{Name: "qwen3:1.7b", Size: "1.1 GB", Params: "1.7B", Quant: "Q4_K_M", Recommended: false},
	{Name: "llama3.2:3b", Size: "2.0 GB", Params: "3B", Quant: "Q4_K_M", Recommended: false},
}

type ModelInfo struct {
	Name        string
	Size        string
	Params      string
	Quant       string
	Recommended bool
}

// ModelStatus describes a model's availability
type ModelStatus struct {
	Available bool
	Path      string
	SizeBytes int64
	IsGGUF    bool
	Error     string
}

// FindModel locates a GGUF model file. Searches:
// 1. Direct path (if absolute or relative file exists)
// 2. ~/.defenseclaw/models/<name>.gguf
// 3. Ollama model blobs
func FindModel(nameOrPath string) ModelStatus {
	// Direct path
	if info, err := os.Stat(nameOrPath); err == nil {
		return ModelStatus{
			Available: true,
			Path:      nameOrPath,
			SizeBytes: info.Size(),
			IsGGUF:    isGGUF(nameOrPath),
		}
	}

	// Check ~/.defenseclaw/models/
	homeDir, _ := os.UserHomeDir()
	localPath := filepath.Join(homeDir, ".defenseclaw", "models", nameOrPath+".gguf")
	if info, err := os.Stat(localPath); err == nil {
		return ModelStatus{
			Available: true,
			Path:      localPath,
			SizeBytes: info.Size(),
			IsGGUF:    true,
		}
	}

	// Check ollama
	ollamaPath := findOllamaModel(nameOrPath)
	if ollamaPath != "" {
		if info, err := os.Stat(ollamaPath); err == nil {
			return ModelStatus{
				Available: true,
				Path:      ollamaPath,
				SizeBytes: info.Size(),
				IsGGUF:    true,
			}
		}
	}

	return ModelStatus{Available: false, Error: "model not found"}
}

// DownloadModel downloads a model via ollama and returns its GGUF path.
func DownloadModel(name string) (string, error) {
	// Check if ollama is available
	if _, err := exec.LookPath("ollama"); err != nil {
		return "", fmt.Errorf("ollama not installed. Install from https://ollama.ai or download GGUF manually")
	}

	fmt.Fprintf(os.Stderr, "→ Downloading %s via ollama...\n", name)
	cmd := exec.Command("ollama", "pull", name)
	cmd.Stdout = os.Stderr
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("ollama pull failed: %w", err)
	}

	// Find the downloaded model
	path := findOllamaModel(name)
	if path == "" {
		return "", fmt.Errorf("model downloaded but GGUF path not found")
	}

	// Create a symlink in ~/.defenseclaw/models/ for easy access
	homeDir, _ := os.UserHomeDir()
	modelsDir := filepath.Join(homeDir, ".defenseclaw", "models")
	os.MkdirAll(modelsDir, 0755)
	linkPath := filepath.Join(modelsDir, strings.ReplaceAll(name, ":", "-")+".gguf")
	os.Remove(linkPath) // remove old symlink
	os.Symlink(path, linkPath)

	fmt.Fprintf(os.Stderr, "  ✓ Model ready: %s\n", linkPath)
	fmt.Fprintf(os.Stderr, "  ✓ Size: %.1f GB\n", float64(fileSize(path))/(1024*1024*1024))
	return linkPath, nil
}

// EnsureModel finds or downloads a model, returning the GGUF path.
func EnsureModel(nameOrPath string) (string, error) {
	status := FindModel(nameOrPath)
	if status.Available {
		if !status.IsGGUF {
			return "", fmt.Errorf("%s is not a GGUF file. Convert with: llama-quantize", status.Path)
		}
		return status.Path, nil
	}

	// Try to download
	return DownloadModel(nameOrPath)
}

// ListModels returns available models (local + ollama)
func ListModels() []string {
	var models []string

	// Check ~/.defenseclaw/models/
	homeDir, _ := os.UserHomeDir()
	modelsDir := filepath.Join(homeDir, ".defenseclaw", "models")
	entries, _ := os.ReadDir(modelsDir)
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".gguf") {
			models = append(models, filepath.Join(modelsDir, e.Name()))
		}
	}

	// Check ollama models
	out, err := exec.Command("ollama", "list").Output()
	if err == nil {
		for _, line := range strings.Split(string(out), "\n") {
			fields := strings.Fields(line)
			if len(fields) >= 1 && !strings.HasPrefix(fields[0], "NAME") {
				models = append(models, "ollama:"+fields[0])
			}
		}
	}

	return models
}

// findOllamaModel locates the GGUF blob for an ollama model
func findOllamaModel(name string) string {
	homeDir, _ := os.UserHomeDir()
	manifestDir := filepath.Join(homeDir, ".ollama", "models", "manifests", "registry.ollama.ai", "library")

	// Parse model name (e.g., "qwen3:8b" → "qwen3" + "8b")
	parts := strings.SplitN(name, ":", 2)
	modelName := parts[0]
	tag := "latest"
	if len(parts) > 1 {
		tag = parts[1]
	}

	manifestPath := filepath.Join(manifestDir, modelName, tag)
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return ""
	}

	// Parse manifest JSON to find the model layer (largest blob)
	var manifest struct {
		Layers []struct {
			Digest    string `json:"digest"`
			Size      int64  `json:"size"`
			MediaType string `json:"mediaType"`
		} `json:"layers"`
	}
	if json.Unmarshal(data, &manifest) != nil {
		return ""
	}

	// Find the largest layer (the model weights)
	var bestDigest string
	var bestSize int64
	for _, layer := range manifest.Layers {
		if layer.Size > bestSize {
			bestSize = layer.Size
			bestDigest = layer.Digest
		}
	}

	if bestDigest == "" {
		return ""
	}

	// Digest format: "sha256:abc123..." → blob path
	blobPath := filepath.Join(homeDir, ".ollama", "models", "blobs", strings.Replace(bestDigest, ":", "-", 1))
	if _, err := os.Stat(blobPath); err == nil {
		return blobPath
	}
	return ""
}

func isGGUF(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()
	magic := make([]byte, 4)
	f.Read(magic)
	return string(magic) == "GGUF"
}

func fileSize(path string) int64 {
	info, err := os.Stat(path)
	if err != nil {
		return 0
	}
	return info.Size()
}
