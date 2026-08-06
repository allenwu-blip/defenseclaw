package managed

import (
	"os"

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
