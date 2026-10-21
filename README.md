# Solutron telepítő

A Solutron IP-alközpont appliance telepítője. Egy szűz Debian 13 hostot alakít Solutron-appliance-szé: Dockert telepít, ellenőrzi az image-ek aláírását, és elindítja az Asterisket és a Solutront.

> ⚠️ **A telepítő átveszi a hostot.** Csak erre a célra szánt, friss Debian 13 gépen futtasd, ne meglévő szerveren.

> **Átmeneti mód:** jelenleg a telepítő GitHub-tokennel (GHCR, `read:packages`) húzza le az image-eket. Laborhasználatra szánt; az éles telepítés licenckulccsal fog működni.

## Követelmények

- Debian 13 (trixie), amd64, friss telepítés, VM vagy bare metal
- root hozzáférés
- Kimenő HTTPS: `ghcr.io`, `download.docker.com`, `github.com`, a Debian tükrök és a Sigstore szolgáltatásai (az aláírás-ellenőrzéshez)

## Telepítés

Rootként:

```sh
curl -fsSL https://raw.githubusercontent.com/Solutron-Hungary/ippbxinstaller/main/install.sh -o install.sh
less install.sh      # érdemes átnézni, mielőtt rootként futtatod
bash install.sh
```

A telepítő bekéri a GitHub-felhasználónevet és a tokent. Nem interaktív futtatáshoz:

```sh
GHCR_USER=... GHCR_TOKEN=... bash install.sh
```

A végén kiírja a webes felület címét: `http://<host-ip>:8080/`.

## Mit csinál

1. Ellenőrzi a környezetet: root, Debian 13, amd64, elérhető registry.
2. Telepíti a Dockert a hivatalos apt-repóból, a kulcs ujjlenyomatát ellenőrizve, majd befagyasztja a verzióját (a frissítést a Solutron kezeli).
3. Telepíti a cosignt (checksummal ellenőrizve).
4. **Ellenőrzi az image-ek aláírását**, és csak ezután húzza le őket, digest alapján. Aláírás nélküli vagy idegen image-et nem telepít.
5. Létrehozza a könyvtárakat (`/srv/solutron`, `/var/lib/solutron`), és elindítja a szolgáltatásokat.
6. Megvárja, hogy minden egészséges legyen.

Újrafuttatható: ilyenkor újraellenőriz, frissíti az image-eket és újraindít, a meglévő konfigurációhoz nem nyúl. Napló: `/var/log/solutron-install.log`.

## Beállítások

| Változó | Alapérték | Jelentés |
| --- | --- | --- |
| `SOLUTRON_TAG` | `0.1.0` | Solutron-verzió (image tag); `main` a legfrissebb fejlesztői build |
| `ASTERISK_TAG` | `24.0.0-rc2` | Asterisk image tag |
| `COSIGN_VERSION` | `latest` | cosign kiadás, pl. `v2.5.0` |
| `KEEP_GHCR_LOGIN` | `0` | `1` esetén a registry-belépés megmarad a hoston |

## Az image-ek kézi ellenőrzése

```sh
cosign verify ghcr.io/solutron-hungary/ippbxsystem/asterisk:24.0.0-rc2 \
  --certificate-identity-regexp '^https://github.com/Solutron-Hungary/ippbxsystem/\.github/workflows/_image\.yml@refs/(heads/main|tags/v.*)$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Licenc

A telepítőszkript MIT licencű (lásd `LICENSE`). A Solutron szoftver nem nyílt forrású; a telepített Asterisk-image GPL-es összetevőinek forrását a kiadások mellett tesszük közzé.
