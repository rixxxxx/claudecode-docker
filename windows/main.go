// Windows one-click onboarding for this repo: checks virtualization, enables
// WSL2, imports a vanilla Ubuntu 26.04, installs Docker Engine from Docker's
// own apt repo (not Ubuntu's outdated docker.io package), then clones this
// repo and runs its own install.sh inside WSL. See
// docs/windows-onboarding.md for the user-facing explanation and the known
// limitations (first-run reboot, the rootfs URL below needing confirmation).
//
// Every stage below checks whether it's already done before acting, so
// re-running this same .exe (e.g. after the reboot WSL2 enablement usually
// needs) just continues from where it left off instead of starting over.
package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

const (
	distroName = "ClaudeCodeSandbox"
	repoURL    = "https://github.com/rixxxxx/claudecode-docker.git"
	repoDir    = "claudecode-docker"

	// Open item (see docs/windows-onboarding.md "Known limitations"): confirm
	// this against Canonical's actual published WSL rootfs layout for 26.04
	// before the first real run -- kept as a single constant for exactly
	// this reason.
	ubuntuRootfsURL = "https://cloud-images.ubuntu.com/wsl/releases/26.04/current/ubuntu-26.04-wsl-amd64-wsl.rootfs.tar.gz"
)

func main() {
	ensureElevated()

	step("Checking virtualization firmware")
	if !virtualizationEnabled() {
		fail(
			"Virtualization is disabled in your BIOS/UEFI firmware. This can't be\n" +
				"turned on from Windows -- reboot, enter BIOS/UEFI setup (usually Del/F2\n" +
				"during boot), enable Intel VT-x or AMD-V, save, then run this program\n" +
				"again.",
		)
	}
	ok("Virtualization is enabled")

	step("Checking WSL2")
	if !wslReady() {
		if err := installWSL(); err != nil {
			fail("Failed to install WSL2: " + err.Error())
		}
		if !wslReady() {
			fail(
				"WSL2 was just installed and needs a reboot before continuing.\n" +
					"Please reboot Windows, then run this program again -- it will pick up\n" +
					"right where it left off.",
			)
		}
	}
	ok("WSL2 is ready")

	step("Enabling WSL2 mirrored networking")
	if err := ensureMirroredNetworking(); err != nil {
		fail("Failed to configure mirrored networking: " + err.Error())
	}
	ok("Mirrored networking is configured")

	step("Checking for the " + distroName + " distro")
	if !distroExists() {
		if err := importUbuntu(); err != nil {
			fail("Failed to import Ubuntu 26.04: " + err.Error())
		}
	}
	ok(distroName + " is imported")

	step("Enabling systemd inside " + distroName)
	if err := ensureSystemd(); err != nil {
		fail("Failed to enable systemd: " + err.Error())
	}
	ok("systemd is enabled")

	step("Installing Docker Engine from Docker's official apt repo")
	if !dockerInstalled() {
		if err := installDocker(); err != nil {
			fail("Failed to install Docker: " + err.Error())
		}
	}
	ok("Docker Engine is installed")

	step("Cloning this repo and running install.sh")
	if err := cloneAndInstall(); err != nil {
		fail("Failed to set up the repo: " + err.Error())
	}
	ok("install.sh completed")

	fmt.Println()
	fmt.Println("==> All done. To get started:")
	fmt.Println("      1. Open \"Ubuntu\" via: wsl -d " + distroName)
	fmt.Println("      2. cd into a project directory")
	fmt.Println("      3. Run: cc-container")
}

// --- output helpers, matching this repo's bash scripts' "==>" log style ---

func step(msg string) { fmt.Println("==> " + msg + "...") }
func ok(msg string)   { fmt.Println("    " + msg) }
func fail(msg string) {
	fmt.Fprintln(os.Stderr, "\nERROR: "+msg)
	os.Exit(1)
}

// --- elevation ---

// net session with no arguments fails with access-denied unless the current
// process is already elevated -- the standard dependency-free way to check
// this without pulling in golang.org/x/sys/windows.
func isElevated() bool {
	return exec.Command("net", "session").Run() == nil
}

func ensureElevated() {
	if isElevated() {
		return
	}
	exe, err := os.Executable()
	if err != nil {
		fail("Could not determine my own path to relaunch elevated: " + err.Error())
	}
	step("Requesting administrator privileges")
	cmd := exec.Command("powershell", "-NoProfile", "-Command",
		fmt.Sprintf("Start-Process -FilePath '%s' -Verb RunAs", exe))
	if err := cmd.Run(); err != nil {
		fail("Could not relaunch elevated (UAC prompt declined?): " + err.Error())
	}
	os.Exit(0)
}

// --- powershell / wsl helpers ---

func powershell(script string) (string, error) {
	out, err := exec.Command("powershell", "-NoProfile", "-Command", script).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

func wsl(args ...string) (string, error) {
	out, err := exec.Command("wsl.exe", args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// --- stage 1: virtualization ---

func virtualizationEnabled() bool {
	out, err := powershell("(Get-CimInstance Win32_Processor).VirtualizationFirmwareEnabled")
	return err == nil && strings.EqualFold(strings.TrimSpace(out), "True")
}

// --- stage 2: WSL2 ---

func wslReady() bool {
	_, err := wsl("--status")
	return err == nil
}

func installWSL() error {
	// The modern one-shot command: enables the Windows-Subsystem-for-Linux
	// and VirtualMachinePlatform features and installs the WSL2 kernel.
	// --no-distribution: we import our own rootfs in the next stage instead
	// of the curated Microsoft Store default.
	_, err := wsl("--install", "--no-distribution")
	return err
}

// ensureMirroredNetworking turns on WSL2's mirrored networking mode (the
// distro shares the host's network interfaces directly instead of going
// through a NAT'd virtual switch) via the global, per-user .wslconfig --
// needed on Windows 11 23H2+; older builds don't support this mode at all.
// This is a global setting, not something docker-compose.yml or squid.conf
// in this repo need to know about -- it only affects how WSL2 itself reaches
// the network, not the internal/external Docker networks inside it.
func ensureMirroredNetworking() error {
	userProfile := os.Getenv("USERPROFILE")
	if userProfile == "" {
		return fmt.Errorf("%%USERPROFILE%% is not set")
	}
	path := filepath.Join(userProfile, ".wslconfig")

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	updated, changed := withMirroredNetworking(string(existing))
	if !changed {
		return nil
	}
	if err := os.WriteFile(path, []byte(updated), 0o644); err != nil {
		return err
	}

	// A .wslconfig change only takes effect once every running WSL2 instance
	// has been torn down -- harmless this early, since no distro has been
	// imported or started yet at this point in the flow.
	_, err = wsl("--shutdown")
	return err
}

// withMirroredNetworking ensures a [wsl2] section with
// networkingMode=mirrored exists in the given .wslconfig content, without
// disturbing any other settings a user may already have in there (memory
// limits, .wslconfig for a different purpose, etc.). Returns the updated
// content and whether anything actually changed, so the caller can skip the
// wsl --shutdown this requires when it's already set correctly.
func withMirroredNetworking(content string) (string, bool) {
	var lines []string
	if content != "" {
		lines = strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")
	}

	sectionStart, sectionEnd, settingLine := -1, -1, -1
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		switch {
		case strings.EqualFold(trimmed, "[wsl2]"):
			sectionStart, sectionEnd = i, len(lines)
		case sectionStart != -1 && sectionEnd == len(lines) &&
			strings.HasPrefix(trimmed, "[") && strings.HasSuffix(trimmed, "]"):
			sectionEnd = i
		case sectionStart != -1 && sectionEnd == len(lines) &&
			strings.HasPrefix(strings.ToLower(trimmed), "networkingmode"):
			settingLine = i
		}
	}

	const setting = "networkingMode=mirrored"

	if settingLine != -1 {
		if strings.EqualFold(strings.TrimSpace(lines[settingLine]), setting) {
			return content, false
		}
		lines[settingLine] = setting
		return strings.Join(lines, "\n") + "\n", true
	}

	if sectionStart != -1 {
		out := make([]string, 0, len(lines)+1)
		out = append(out, lines[:sectionStart+1]...)
		out = append(out, setting)
		out = append(out, lines[sectionStart+1:]...)
		return strings.Join(out, "\n") + "\n", true
	}

	if content != "" && !strings.HasSuffix(content, "\n") {
		content += "\n"
	}
	return content + "[wsl2]\n" + setting + "\n", true
}

// --- stage 3: Ubuntu 26.04 import ---

func distroExists() bool {
	out, err := wsl("-l", "-q")
	if err != nil {
		return false
	}
	for _, line := range strings.Split(out, "\n") {
		// wsl -l -q prints UTF-16-ish output that can carry a stray \r and
		// null bytes on some builds -- strip both before comparing.
		clean := strings.ReplaceAll(strings.TrimSpace(line), "\x00", "")
		if clean == distroName {
			return true
		}
	}
	return false
}

func importUbuntu() error {
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		return fmt.Errorf("%%LOCALAPPDATA%% is not set")
	}
	installDir := filepath.Join(localAppData, distroName)
	if err := os.MkdirAll(installDir, 0o755); err != nil {
		return err
	}

	rootfsPath := filepath.Join(os.TempDir(), "ubuntu-26.04-wsl.rootfs.tar.gz")
	fmt.Println("    Downloading " + ubuntuRootfsURL)
	if err := downloadFile(ubuntuRootfsURL, rootfsPath); err != nil {
		return fmt.Errorf("downloading rootfs: %w", err)
	}
	defer os.Remove(rootfsPath)

	_, err := wsl("--import", distroName, installDir, rootfsPath, "--version", "2")
	return err
}

func downloadFile(url, dest string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("unexpected status %s fetching %s", resp.Status, url)
	}

	out, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer out.Close()

	_, err = io.Copy(out, resp.Body)
	return err
}

// --- stage 4: systemd ---

// Imported rootfs tarballs default to a root user, so no sudo is needed for
// anything run inside the distro throughout this program.
func ensureSystemd() error {
	const wslConf = `[boot]
systemd=true
`
	script := fmt.Sprintf("printf '%s' > /etc/wsl.conf", wslConf)
	if _, err := wsl("-d", distroName, "--", "bash", "-c", script); err != nil {
		return err
	}
	// Restart the distro so systemd actually takes effect -- only this one
	// distro, not --shutdown, which would also kill any other WSL distros
	// the user already has running.
	_, err := wsl("--terminate", distroName)
	return err
}

// --- stage 5: Docker ---

func dockerInstalled() bool {
	_, err := wsl("-d", distroName, "--", "bash", "-c", "command -v docker")
	return err == nil
}

func installDocker() error {
	// Docker's own documented apt-repository steps (docs.docker.com "Install
	// using the apt repository"), not the docker.io package Ubuntu ships,
	// and not the curl-pipe-to-shell convenience script.
	script := `set -e
apt-get update
apt-get install -y ca-certificates curl gnupg git
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker
`
	_, err := wsl("-d", distroName, "--", "bash", "-c", script)
	return err
}

// --- stage 6: clone + install.sh ---

func cloneAndInstall() error {
	script := fmt.Sprintf(`set -e
if [ -d ~/%s/.git ]; then
  cd ~/%s && git pull
else
  git clone %s ~/%s
fi
cd ~/%s && bash install.sh
`, repoDir, repoDir, repoURL, repoDir, repoDir)
	_, err := wsl("-d", distroName, "--", "bash", "-c", script)
	return err
}
