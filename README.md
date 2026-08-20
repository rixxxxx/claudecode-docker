# Claude Code – Isolierter Docker-Container

Eigenständiges Docker-Setup für Claude Code (Anthropic CLI), ohne Microsoft
Dev-Container-Spezifikation. Netzwerk-Isolation erfolgt auf Docker-Compose-
Ebene über ein internes Netzwerk + Egress-Proxy, nicht über iptables im
Container selbst.

## Architektur

    [claude-code Container] ---(internes Netzwerk, kein Internet-Zugang)---> [egress-proxy]
                                                                                    |
                                                                          (externes Netzwerk)
                                                                                    |
                                                                                Internet

- `claude-code`: läuft als non-root User (UID 1000), hat keine direkte Route
  ins Internet — die Route existiert auf Docker-Netzwerk-Ebene schlicht nicht.
- `egress-proxy`: Squid mit Domain-Allowlist, einziger erlaubter Ausgang.
  Filtert nach Domain (SNI), nicht nach IP — robust gegenüber rotierenden
  CDN-IPs.

## Dateien

| Datei                | Zweck                                                        |
|-----------------------|---------------------------------------------------------------|
| `Dockerfile`           | Baut das Claude-Code-Image (Ubuntu 26.04, Node 24 via NodeSource, gh CLI) |
| `docker-compose.yml`   | Orchestriert `claude-code` + `egress-proxy`, definiert Netzwerke |
| `squid.conf`           | Domain-Allowlist für den Egress-Proxy                        |
| `entrypoint.sh`        | Terminal-Setup + Welcome-Banner, startet interaktive Shell    |
| `.dockerignore`        | Schließt Secrets, node_modules, .git etc. vom Build-Kontext aus |
| `.gitignore`           | Schließt Secrets, Credentials, Build-Artefakte vom Repo aus   |

## Setup

1. Repo/Projektordner mit diesen Dateien anlegen
2. Container bauen und starten:

```bash
   docker compose up -d
```

3. In den Container einloggen:

```bash
   docker compose exec claude-code bash
```

4. Claude Code starten und mit Pro/Max-Abo anmelden:

```bash
   claude
   # dann: /login
```

   Der Login-Link muss im Host-Browser geöffnet werden (kein Browser im
   Container). Der OAuth-Callback läuft über `claude.ai` — diese Domain ist
   in `squid.conf` erlaubt.

## Persistenz

Standardmäßig geht der OAuth-Login bei jedem `docker compose down` verloren,
da `/home/claudecode/.claude` nicht gemountet ist. Für persistente Anmeldung
in `docker-compose.yml` ergänzen:

```yaml
services:
  claude-code:
    volumes:
      - .:/workspace
      - claude-config:/home/claudecode/.claude

volumes:
  claude-config:
```

Alternativ, um die Login-Daten vom Host wiederzuverwenden (falls dort
bereits `claude login` ausgeführt wurde):

```yaml
    volumes:
      - ${HOME}/.claude:/home/claudecode/.claude
```

## Domain-Allowlist erweitern

Neue Domain (z. B. eine private Registry) in `squid.conf` ergänzen:
acl allowed_domains dstdomain internal.registry.company.com


Danach Proxy neu starten:

```bash
docker compose restart egress-proxy
```

## Troubleshooting

Blockierte Verbindungen im Proxy-Log finden:

```bash
docker compose logs egress-proxy | grep TCP_DENIED
```

DNS-Auflösung im Claude-Code-Container testen:

```bash
docker compose exec claude-code nslookup api.anthropic.com
```

## Bekannte Einschränkungen

- Die Firewall schützt vor Exfiltration zu unbekannten Zielen, nicht vor
  Missbrauch der erlaubten Domains selbst (z. B. `api.anthropic.com`).
- Bei Nutzung von `--dangerously-skip-permissions` bleibt das Risiko
  bestehen, dass ein bösartiges Projekt alles im Container Zugängliche
  über eine erlaubte Domain exfiltrieren könnte. Nur mit vertrauenswürdigen
  Repositories verwenden.
- Neue Anthropic-Domains (z. B. bei Feature-Updates) werden nicht
  automatisch erkannt — `squid.conf` muss manuell gepflegt werden.

## Sicherheitsmodell im Vergleich

| Ansatz                          | Rechte im claude-code-Container | Robustheit ggü. CDN-IP-Rotation |
|----------------------------------|----------------------------------|-----------------------------------|
| iptables im Container (verworfen) | root-Start, NET_ADMIN nötig     | Niedrig (IP-basiert)              |
| Docker-Compose-Netzwerk (aktuell) | durchgehend non-root            | Hoch (Domain-basiert via SNI)     |
