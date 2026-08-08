package managed

import (
	"os"
	"path/filepath"

	"github.com/defenseclaw/defenseclaw/internal/safefile"
)

// PinnedDeploymentMode reports the machine-wide deployment mode pin. Callers
// without a loaded config use it to tell a managed runtime tree from a
// self-managed one.
func PinnedDeploymentMode() string {
	return os.Getenv(DeploymentModeEnv)
}

// PrepareServiceRuntimeDir readies a gateway runtime directory for use.
//
// safefile enforces a private-state contract: the caller must be the sole
// owner. A managed enterprise runtime tree is installer-provisioned and
// Administrators-owned with a service-SID writer ACE, so that contract does not
// hold and safefile would both reject the owner and rewrite the canonical DACL.
// Managed paths are validated against the managed trust model instead, which
// accepts exactly that layout.
func PrepareServiceRuntimeDir(deploymentMode, path, label string) error {
	if !IsManagedEnterprise(deploymentMode) {
		return safefile.ProtectDirectory(path)
	}
	// Only the leaf is created. A missing ancestor means the installer-provisioned
	// tree is incomplete, which must surface rather than be filled in here.
	if err := os.Mkdir(path, 0o700); err != nil && !os.IsExist(err) {
		return err
	}
	return ValidateTrustedServiceRuntimeDir(path, label, os.Getenv(WindowsServiceAccountEnv))
}

// PrepareServiceRuntimeFile is the regular-file counterpart to
// PrepareServiceRuntimeDir. The file must already exist.
func PrepareServiceRuntimeFile(deploymentMode, path, label string) error {
	if IsManagedEnterprise(deploymentMode) {
		return ValidateTrustedServiceRuntimeFilePath(path, label, os.Getenv(WindowsServiceAccountEnv))
	}
	return safefile.ProtectFile(path)
}

// WriteServiceRuntimeFile atomically publishes a file the gateway owns at
// runtime, such as a generated token or persisted state.
//
// safefile.WritePrivate imposes the private-state contract on the parent
// directory before writing: sole ownership by the writer, and a DACL of that
// owner plus SYSTEM. A managed enterprise runtime directory is
// installer-provisioned, Administrators-owned, and shared with the service
// through a narrow writer ACE, so the contract cannot hold; applying it would
// also strip the Administrators ACE the installer's verifier requires. Managed
// paths are validated against the managed trust model and published in place,
// leaving the installer's inheritable DACL to govern the result.
func WriteServiceRuntimeFile(deploymentMode, path, label string, data []byte) error {
	if !IsManagedEnterprise(deploymentMode) {
		return safefile.WritePrivate(path, data)
	}
	if label == "" {
		label = "managed runtime file"
	}
	serviceAccount := os.Getenv(WindowsServiceAccountEnv)
	if err := ValidateTrustedServiceRuntimeDir(
		filepath.Dir(path), label+" directory", serviceAccount,
	); err != nil {
		return err
	}
	// A replacement keeps the destination's own descriptor, so an existing file
	// has to prove it is still trusted before it is written through.
	if _, err := os.Lstat(path); err == nil {
		if err := ValidateTrustedServiceRuntimeFilePath(path, label, serviceAccount); err != nil {
			return err
		}
	} else if !os.IsNotExist(err) {
		return err
	}
	return publishServiceRuntimeFile(path, data)
}

func publishServiceRuntimeFile(path string, data []byte) error {
	temporary, err := os.CreateTemp(filepath.Dir(path), ".defenseclaw-runtime-*")
	if err != nil {
		return err
	}
	name := temporary.Name()
	defer func() { _ = os.Remove(name) }()
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return err
	}
	if err := temporary.Close(); err != nil {
		return err
	}
	return safefile.ReplaceFile(name, path)
}
