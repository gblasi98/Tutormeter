# Tutormeter — Setup Guida CI/CD

## 1. App Store Connect — Registrare l'app

### 1.1 Crea l'App ID su Apple Developer
1. Vai su https://developer.apple.com/account
2. **Certificates, Identifiers & Profiles** → **Identifiers**
3. Clicca **+** (in alto) → **App IDs**
4. Seleziona **App** e clicca **Continue**
5. Compila:
   - **Description**: `Tutormeter`
   - **Bundle ID**: `com.tutormeter.app` (Explicit)
   - **Capabilities** da abilitare:
     - ✅ Background Modes (Location, Audio, Fetch)
     - ✅ Push Notifications (per Live Activities)
     - ✅ Siri
6. Clicca **Register**

### 1.2 Crea l'app su App Store Connect
1. Vai su https://appstoreconnect.apple.com
2. **My Apps** → clicca **+** → **New App**
3. Compila:
   - **Platform**: iOS
   - **Name**: `Tutormeter`
   - **Primary Language**: Italian
   - **Bundle ID**: `com.tutormeter.app` (quello creato sopra)
   - **SKU**: `com.tutormeter.app`
   - **User Access**: Full Access
4. Clicca **Create**

### 1.3 Genera API Key per Codemagic
1. App Store Connect → **Users and Access** → **Integrations** tab
2. **App Store Connect API** → **Team Keys** → clicca **+**
3. Dai un nome (es. `Codemagic CI`) e seleziona ruolo **App Manager**
4. **Generate** → scarica il file `.p8` (NON perderlo!)
5. Prendi nota di:
   - **Issuer ID** (in alto nella pagina API Keys)
   - **Key ID** (mostrato dopo la generazione)
   - **Contenuto del file .p8** (Aprilo con Notepad, inizia con `-----BEGIN PRIVATE KEY-----`)

---

## 2. Codemagic — Configurazione

### 2.1 Connetti il repository
1. Vai su https://codemagic.io
2. Clicca **Add application**
3. Seleziona **GitHub** → autorizza l'accesso a `gblasi98/Tutormeter`
4. Seleziona il repository **gblasi98/Tutormeter**
5. **Project type**: `iOS App` (o `Other`)

### 2.2 Configura le variabili encrypted (IMPORTANTE: NON committare mai queste chiavi!)
Nel progetto Codemagic, vai su **App settings** → **Environment variables** e aggiungi:

| Nome Variabile | Valore | Gruppo |
|---|---|---|
| `APP_STORE_CONNECT_ISSUER_ID` | Il tuo Issuer ID (dal passo 1.3) | `appstore` |
| `APP_STORE_CONNECT_KEY_ID` | Il tuo Key ID (dal passo 1.3) | `appstore` |
| `APP_STORE_CONNECT_PRIVATE_KEY` | Contenuto COMPLETO del file `.p8` | `appstore` |
| `CERTIFICATE_PRIVATE_KEY` | Chiave privata certificato (o `""` per auto-signing in dev) | `signing` |

**Nota per build di sviluppo**: per la prima build, le variabili di signing possono essere vuote — Codemagic userà il code signing automatico. Per TestFlight serve il setup completo.

### 2.3 Configura il workflow
Nel progetto Codemagic, vai su **Workflow settings**:
  - **Workflow type**: YAML (legge `codemagic.yaml` dal repo)
  - Il file `codemagic.yaml` è già nel repo con 3 workflow pronti:
    - `ios-dev-build` — si attiva su push a `main`/`develop`/`feature/*`
    - `ios-testflight` — si attiva su tag `release/*` o `beta/*`
    - `ios-pr-check` — si attiva su pull request

### 2.4 Aggiorna l'email di notifica
Nel `codemagic.yaml`, modifica l'email nel publishing block:
```yaml
publishing:
  email:
    recipients:
      - la-tua-email@esempio.com  # <-- CAMBIA QUESTO
```

### 2.5 Crea il gruppo TestFlight (opzionale per primo test)
1. App Store Connect → **My Apps** → **Tutormeter** → **TestFlight**
2. Crea un gruppo test (es. `Tutormeter Internal Testers`)
3. Aggiungi te stesso come tester

---

## 3. Primo push per testare la build

```powershell
cd C:\Users\hp\Desktop\Applicazione\Tutormeter
git add -A
git commit -m "chore: update Codemagic config"
git push
```

Dopo il push, Codemagic eseguirà:
1. `brew install xcodegen` → installa XcodeGen
2. `xcodegen generate --spec project.yml` → genera il `.xcodeproj`
3. `xcodebuild test ...` → esegue i 12 unit test
4. `xcodebuild archive ...` → crea l'archivio

---

## Riepilogo rapido

| Passo | Dove | Azione |
|---|---|---|
| 1.1 | developer.apple.com | Crea App ID `com.tutormeter.app` |
| 1.2 | appstoreconnect.apple.com | Registra app Tutormeter |
| 1.3 | appstoreconnect.apple.com | Genera API Key (.p8) |
| 2.1 | codemagic.io | Connetti repo GitHub |
| 2.2 | codemagic.io | Aggiungi variabili encrypted |
| 2.5 | appstoreconnect.apple.com | Crea gruppo TestFlight |
| 3 | PowerShell | `git push` per triggerare build |

**Tempo stimato**: 15-20 minuti per tutti i passaggi.
