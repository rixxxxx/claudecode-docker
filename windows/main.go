// Windows one-click onboarding for this repo: checks virtualization, enables
// WSL2, imports a vanilla Ubuntu 26.04, creates a non-root default user,
// installs Docker Engine from Docker's own apt repo (not Ubuntu's outdated
// docker.io package), then clones this repo and runs its own install.sh
// inside WSL as that user. See docs/windows-onboarding.md for the
// user-facing explanation and the known limitations (first-run reboot, the
// rootfs URL below needing confirmation).
//
// Every stage below checks whether it's already done before acting, so
// re-running this same .exe (e.g. after the reboot WSL2 enablement usually
// needs) just continues from where it left off instead of starting over.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	distroName = "ClaudeCodeSandbox"
	repoURL    = "https://github.com/rixxxxx/claudecode-docker.git"
	repoDir    = "claudecode-docker"

	// The claude-code container runs as UID 1000 (see Dockerfile) -- the WSL
	// user owning the workspaces has to match, or the container can't write
	// to its own bind-mounted /workspace.
	linuxUID         = 1000
	fallbackUsername = "claude"

	// Confirmed 2026-09-25 against Canonical's signed SHA256SUMS for 26.04.
	// Names the point release, so it goes stale with the next one (26.04.2)
	// -- overridable via -rootfs-url for exactly this reason.
	defaultRootfsURL = "https://releases.ubuntu.com/26.04/ubuntu-26.04.1-wsl-amd64.wsl"

	// Folder next to the .exe that, if present, supplies the image and its
	// SHA256SUMS/SHA256SUMS.gpg locally instead of downloading them.
	localImageDirName = "wsl-image"
)

var (
	rootfsURL = flag.String("rootfs-url", defaultRootfsURL,
		"Ubuntu WSL image to download when no local image folder exists; SHA256SUMS(.gpg) are fetched from the same directory")
	imageDir = flag.String("image-dir", "",
		"folder with a local .wsl image plus SHA256SUMS and SHA256SUMS.gpg (default: "+localImageDirName+" next to this .exe, if it exists)")
)

func main() {
	flag.Parse()
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

	step("Creating a non-root user (UID " + fmt.Sprint(linuxUID) + ") inside " + distroName)
	user, err := ensureUser(linuxUsername(os.Getenv("USERNAME")))
	if err != nil {
		fail("Failed to create the user: " + err.Error())
	}
	ok("User " + user + " is ready")

	step("Enabling systemd and the default user inside " + distroName)
	if err := ensureWSLConf(user); err != nil {
		fail("Failed to write /etc/wsl.conf: " + err.Error())
	}
	ok("systemd is enabled, " + user + " is the default user")

	step("Installing Docker Engine from Docker's official apt repo")
	if !dockerInstalled() {
		if err := installDocker(); err != nil {
			fail("Failed to install Docker: " + err.Error())
		}
	}
	if err := ensureDockerGroup(user); err != nil {
		fail("Failed to add " + user + " to the docker group: " + err.Error())
	}
	ok("Docker Engine is installed, " + user + " can use it without sudo")

	step("Cloning this repo and running install.sh as " + user)
	if err := cloneAndInstall(user); err != nil {
		fail("Failed to set up the repo: " + err.Error())
	}
	ok("install.sh completed")

	fmt.Println()
	fmt.Println("==> All done. To get started:")
	fmt.Println("      1. Open the sandbox distro (logs in as " + user + "): wsl -d " + distroName)
	fmt.Println("      2. cd into a project directory")
	fmt.Println("      3. Run: cc-container")
	waitForEnter()
}

// --- output helpers, matching this repo's bash scripts' "==>" log style ---

func step(msg string) { fmt.Println("==> " + msg + "...") }
func ok(msg string)   { fmt.Println("    " + msg) }
func fail(msg string) {
	fmt.Fprintln(os.Stderr, "\nERROR: "+msg)
	waitForEnter()
	os.Exit(1)
}

// After the UAC relaunch this runs in its own console window, which closes
// the moment the process exits -- without this, neither the final
// instructions nor an error message would stay on screen long enough to read.
func waitForEnter() {
	fmt.Print("\nPress Enter to close this window...")
	_, _ = bufio.NewReader(os.Stdin).ReadString('\n')
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
	// Forward our own flags (e.g. -rootfs-url) to the elevated copy -- the
	// relaunch is a fresh process that would otherwise silently lose them.
	script := "Start-Process -FilePath " + psQuote(exe) + " -Verb RunAs"
	if args := os.Args[1:]; len(args) > 0 {
		quoted := make([]string, len(args))
		for i, a := range args {
			quoted[i] = psQuote(a)
		}
		script += " -ArgumentList " + strings.Join(quoted, ",")
	}
	if _, err := powershell(script); err != nil {
		fail("Could not relaunch elevated (UAC prompt declined?): " + err.Error())
	}
	os.Exit(0)
}

// psQuote wraps s in a PowerShell single-quoted string literal, where the
// only character needing escaping is the single quote itself (doubled).
func psQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "''") + "'"
}

// --- powershell / wsl helpers ---

func powershell(script string) (string, error) {
	out, err := exec.Command("powershell", "-NoProfile", "-Command", script).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// wsl.exe's own messages are UTF-16LE by default; WSL_UTF8=1 makes them
// plain UTF-8 so the output parsing below (and the console) can read them.
func wslCommand(args ...string) *exec.Cmd {
	cmd := exec.Command("wsl.exe", args...)
	cmd.Env = append(os.Environ(), "WSL_UTF8=1")
	return cmd
}

func wsl(args ...string) (string, error) {
	out, err := wslCommand(args...).CombinedOutput()
	return strings.TrimSpace(string(out)), err
}

// wslStream is wsl() for the long-running stages (WSL install, apt, git
// clone, install.sh): passes output straight through to the console so
// there's visible progress instead of minutes of silence.
func wslStream(args ...string) error {
	cmd := wslCommand(args...)
	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr
	return cmd.Run()
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
	return wslStream("--install", "--no-distribution")
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
	cfgPath := filepath.Join(userProfile, ".wslconfig")

	existing, err := os.ReadFile(cfgPath)
	if err != nil && !os.IsNotExist(err) {
		return err
	}

	updated, changed := withMirroredNetworking(string(existing))
	if !changed {
		return nil
	}
	if err := os.WriteFile(cfgPath, []byte(updated), 0o644); err != nil {
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
		// Drop the empty element a trailing newline leaves behind, or every
		// rewrite below would append one more blank line to the file.
		lines = strings.Split(strings.TrimSuffix(strings.ReplaceAll(content, "\r\n", "\n"), "\n"), "\n")
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
		// Belt and braces alongside WSL_UTF8=1: older wsl.exe builds ignore
		// it and still print UTF-16-ish output with a stray \r and null
		// bytes -- strip both before comparing.
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

	img, cleanup, err := fetchVerifiedImage()
	defer cleanup()
	if err != nil {
		return err
	}
	return wslStream("--import", distroName, installDir, img, "--version", "2")
}

// fetchVerifiedImage returns the path of an Ubuntu WSL image whose SHA256
// matches Canonical's SHA256SUMS, after first checking SHA256SUMS.gpg
// against the pinned Canonical key (see openpgp.go) -- a hash alone only
// proves the download matches whatever server it came from. Uses a local
// image folder when there is one, downloads otherwise; the returned cleanup
// removes a downloaded temp file and never touches local files.
func fetchVerifiedImage() (img string, cleanup func(), err error) {
	cleanup = func() {}
	keys, err := trustedKeys()
	if err != nil {
		return "", cleanup, err
	}

	var sums, sig []byte
	var imgName string
	dir, local, err := resolveImageDir()
	if err != nil {
		return "", cleanup, err
	}
	if local {
		var sumsPath string
		if img, sumsPath, err = findLocalImage(dir); err != nil {
			return "", cleanup, err
		}
		imgName = filepath.Base(img)
		fmt.Println("    Using local " + img)
		if sums, err = os.ReadFile(sumsPath); err != nil {
			return "", cleanup, err
		}
		if sig, err = os.ReadFile(sumsPath + ".gpg"); err != nil {
			return "", cleanup, err
		}
	} else {
		var sumsURL string
		sumsURL, imgName = sha256SumsURL(*rootfsURL)
		fmt.Println("    Fetching " + sumsURL + "(.gpg)")
		if sums, err = fetchBytes(sumsURL); err != nil {
			return "", cleanup, err
		}
		if sig, err = fetchBytes(sumsURL + ".gpg"); err != nil {
			return "", cleanup, err
		}
	}

	key, err := verifyDetachedSignature(sums, sig, keys)
	if err != nil {
		return "", cleanup, fmt.Errorf("SHA256SUMS signature check failed -- refusing to import: %w", err)
	}
	ok("SHA256SUMS signature is valid (" + trustedFingerprints[key.fingerprint] + ", " + key.fingerprint + ")")

	expected, found := parseSHA256Sums(string(sums), imgName)
	if !found {
		return "", cleanup, fmt.Errorf("%s is not listed in the signed SHA256SUMS (renamed file, or SHA256SUMS from a different release?)", imgName)
	}

	var actual string
	if local {
		fmt.Println("    Hashing " + imgName)
		actual, err = hashFile(img)
	} else {
		img = filepath.Join(os.TempDir(), "claudecode-sandbox-"+path.Base(*rootfsURL))
		cleanup = func() { os.Remove(img) }
		fmt.Println("    Downloading " + *rootfsURL)
		actual, err = downloadFile(*rootfsURL, img)
	}
	if err != nil {
		return "", cleanup, err
	}
	if actual != expected {
		return "", cleanup, fmt.Errorf("SHA256 mismatch for %s: expected %s, got %s -- refusing to import", imgName, expected, actual)
	}
	ok("SHA256 of " + imgName + " matches the signed SHA256SUMS")
	return img, cleanup, nil
}

// resolveImageDir picks the local image folder: -image-dir if given (must
// exist), else wsl-image next to the .exe if that exists, else none.
func resolveImageDir() (dir string, local bool, err error) {
	if *imageDir != "" {
		if fi, err := os.Stat(*imageDir); err != nil || !fi.IsDir() {
			return "", false, fmt.Errorf("-image-dir %s is not a folder", *imageDir)
		}
		return *imageDir, true, nil
	}
	exe, err := os.Executable()
	if err != nil {
		return "", false, nil
	}
	dir = filepath.Join(filepath.Dir(exe), localImageDirName)
	if fi, err := os.Stat(dir); err == nil && fi.IsDir() {
		return dir, true, nil
	}
	return "", false, nil
}

// findLocalImage expects exactly one *.wsl image and exactly one
// SHA256SUMS* checksum file (any suffix, e.g. SHA256SUMS_ubuntu-26.04 as a
// browser/manual rename would leave it) with its .gpg signature next to it.
func findLocalImage(dir string) (img, sums string, err error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return "", "", err
	}
	var imgs, sumsFiles []string
	for _, e := range entries {
		name := e.Name()
		switch {
		case e.IsDir():
		case strings.HasSuffix(strings.ToLower(name), ".wsl"):
			imgs = append(imgs, name)
		case strings.HasPrefix(name, "SHA256SUMS") && !strings.HasSuffix(name, ".gpg"):
			sumsFiles = append(sumsFiles, name)
		}
	}
	if len(imgs) != 1 {
		return "", "", fmt.Errorf("%s: expected exactly one .wsl image, found %d %v", dir, len(imgs), imgs)
	}
	if len(sumsFiles) != 1 {
		return "", "", fmt.Errorf("%s: expected exactly one SHA256SUMS file, found %d %v", dir, len(sumsFiles), sumsFiles)
	}
	sums = filepath.Join(dir, sumsFiles[0])
	if _, err := os.Stat(sums + ".gpg"); err != nil {
		return "", "", fmt.Errorf("%s: signature %s.gpg is missing", dir, sumsFiles[0])
	}
	return filepath.Join(dir, imgs[0]), sums, nil
}

// sha256SumsURL returns the SHA256SUMS URL sitting next to the given file
// URL (Canonical publishes one per release directory) and the file name to
// look up in it.
func sha256SumsURL(fileURL string) (sumsURL, fileName string) {
	i := strings.LastIndex(fileURL, "/")
	return fileURL[:i+1] + "SHA256SUMS", fileURL[i+1:]
}

// parseSHA256Sums finds fileName in sha256sum-format output ("<hex>  name"
// or "<hex> *name" for binary mode) and returns its lowercase hash.
func parseSHA256Sums(sums, fileName string) (string, bool) {
	for _, line := range strings.Split(strings.ReplaceAll(sums, "\r\n", "\n"), "\n") {
		fields := strings.Fields(line)
		if len(fields) != 2 {
			continue
		}
		if strings.TrimPrefix(fields[1], "*") == fileName && len(fields[0]) == 64 {
			return strings.ToLower(fields[0]), true
		}
	}
	return "", false
}

func fetchBytes(url string) ([]byte, error) {
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("unexpected status %s fetching %s", resp.Status, url)
	}
	return io.ReadAll(resp.Body)
}

func hashFile(name string) (string, error) {
	f, err := os.Open(name)
	if err != nil {
		return "", err
	}
	defer f.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// downloadFile saves url to dest and returns the hex SHA256 of what it wrote.
func downloadFile(url, dest string) (string, error) {
	resp, err := http.Get(url)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("unexpected status %s fetching %s", resp.Status, url)
	}

	out, err := os.Create(dest)
	if err != nil {
		return "", err
	}
	defer out.Close()

	hash := sha256.New()
	if _, err := io.Copy(io.MultiWriter(out, hash), resp.Body); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

// --- stage 4: non-root user ---

var invalidUsernameChars = regexp.MustCompile(`[^a-z0-9_-]`)

// linuxUsername derives a valid Linux account name from the Windows
// %USERNAME% (lowercased, anything outside [a-z0-9_-] dropped, must start
// with a letter or underscore, max 32 chars), falling back to a fixed name
// when nothing usable is left.
func linuxUsername(windowsName string) string {
	name := invalidUsernameChars.ReplaceAllString(strings.ToLower(windowsName), "")
	name = strings.TrimLeft(name, "0123456789-")
	if len(name) > 32 {
		name = name[:32]
	}
	if name == "" || name == "root" {
		return fallbackUsername
	}
	return name
}

// ensureUser makes sure UID 1000 exists inside the distro and returns its
// name. Imported rootfs tarballs default to root, which would leave
// install.sh, cc-container, and every workspace owned by root -- the
// claude-code container (UID 1000) couldn't write to its own /workspace.
// If some image already ships a UID 1000 account (e.g. "ubuntu"), that one
// is reused rather than fighting over the UID.
func ensureUser(wanted string) (string, error) {
	script := fmt.Sprintf(`set -e
existing=$(getent passwd %[1]d | cut -d: -f1)
if [ -n "$existing" ]; then
  echo "$existing"
  exit 0
fi
if id -u %[2]s >/dev/null 2>&1; then
  echo "user %[2]s already exists with a UID other than %[1]d" >&2
  exit 1
fi
useradd --create-home --uid %[1]d --shell /bin/bash %[2]s
echo %[2]s
`, linuxUID, wanted)
	out, err := wsl("-d", distroName, "-u", "root", "--", "bash", "-c", script)
	if err != nil {
		return "", fmt.Errorf("%w: %s", err, out)
	}
	lines := strings.Split(out, "\n")
	return strings.TrimSpace(lines[len(lines)-1]), nil
}

// --- stage 5: /etc/wsl.conf (systemd + default user) ---

func wslConf(user string) string {
	return fmt.Sprintf("[boot]\nsystemd=true\n\n[user]\ndefault=%s\n", user)
}

// ensureWSLConf enables systemd (needed for dockerd to run as a normal
// service) and makes user the default login. Only restarts the distro when
// the file actually changed -- and then only this one distro, not
// --shutdown, which would also kill any other WSL distros the user already
// has running.
func ensureWSLConf(user string) error {
	want := wslConf(user)
	current, _ := wsl("-d", distroName, "-u", "root", "--", "cat", "/etc/wsl.conf")
	if strings.TrimSpace(current) == strings.TrimSpace(want) {
		return nil
	}
	script := fmt.Sprintf("printf '%s' > /etc/wsl.conf", want)
	if out, err := wsl("-d", distroName, "-u", "root", "--", "bash", "-c", script); err != nil {
		return fmt.Errorf("%w: %s", err, out)
	}
	_, err := wsl("--terminate", distroName)
	return err
}

// --- stage 6: Docker ---

func dockerInstalled() bool {
	_, err := wsl("-d", distroName, "-u", "root", "--", "bash", "-c", "command -v docker")
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
	return wslStream("-d", distroName, "-u", "root", "--", "bash", "-c", script)
}

// ensureDockerGroup is idempotent (usermod -aG on an existing member is a
// no-op) and runs every time rather than only right after installDocker, so
// a run interrupted between the two stages still ends up correct.
func ensureDockerGroup(user string) error {
	out, err := wsl("-d", distroName, "-u", "root", "--", "usermod", "-aG", "docker", user)
	if err != nil {
		return fmt.Errorf("%w: %s", err, out)
	}
	return nil
}

// --- stage 7: clone + install.sh ---

// Runs as the non-root user, not root: install.sh links cc-container into
// that user's ~/.local/bin and PATH, and the clone ends up owned by them.
func cloneAndInstall(user string) error {
	script := fmt.Sprintf(`set -e
cd ~
if [ -d %[1]s/.git ]; then
  cd %[1]s && git pull
else
  git clone %[2]s %[1]s
  cd %[1]s
fi
bash install.sh
`, repoDir, repoURL)
	return wslStream("-d", distroName, "-u", user, "--", "bash", "-c", script)
}
