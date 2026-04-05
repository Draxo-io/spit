# VoiceFlow

App macOS de ditação por voz com Whisper API.

## Estrutura do Projecto

```
VoiceFlow/
├── App/
│   ├── VoiceFlowApp.swift          # Entry point (@main)
│   └── AppDelegate.swift           # Lifecycle, permissões
├── Controllers/
│   ├── DictationController.swift   # State machine principal
│   └── MenuBarController.swift     # Menu bar + popover
├── Services/
│   ├── HotkeyManager.swift         # Atalho global (Carbon API)
│   ├── AudioRecorder.swift         # Gravação (AVAudioEngine)
│   ├── WhisperService.swift        # OpenAI Whisper API
│   ├── FocusDetector.swift         # Detecção de campo activo (AX)
│   └── TextInjector.swift          # Injecção de texto (AX + clipboard)
├── Managers/
│   ├── VocabularyManager.swift     # Substituições personalizadas
│   ├── CreditsManager.swift        # Free trial + BYOK
│   └── KeychainManager.swift       # API key segura
├── UI/
│   ├── MenuBarPopoverView.swift    # Popover da menu bar
│   ├── SettingsView.swift          # Janela de definições
│   ├── ReviewHUDView.swift         # HUD de revisão pós-ditação
│   └── ReviewHUDWindowController.swift
├── Models/
│   └── AppState.swift              # Modelos de dados
└── Resources/
    ├── Info.plist
    └── VoiceFlow.entitlements
```

## Como Compilar

### Pré-requisitos
- Xcode 15+
- XcodeGen: `brew install xcodegen`

### Gerar projecto Xcode
```bash
cd /Users/rafaellopes/projects/VoiceFlow
xcodegen generate
open VoiceFlow.xcodeproj
```

### Configuração antes de compilar
1. Abre o `project.yml` e define o teu `DEVELOPMENT_TEAM`
2. Para o free trial, adiciona a chave do developer no `Info.plist` → `VF_DEV_API_KEY`
3. Para desenvolvimento local, desactiva o App Sandbox no `.entitlements`

## Fluxo de Estados

```
idle ──hotkey──▶ recording ──hotkey──▶ processing ──▶ injecting ──▶ idle
                                                                      ▲
                                                              ReviewHUD (opcional)
```

## Decisões de Distribuição

| Canal | Sandbox | AX Injection | Nota |
|-------|---------|--------------|------|
| App Store | Obrigatório | ❌ (apenas clipboard) | Mais fácil de aprovar |
| Website directo | Opcional | ✅ | Mais funcionalidades |

**Recomendação MVP:** Distribuir pelo website com clipboard fallback first,
depois submeter à App Store sem injecção AX.

## Notas Técnicas

- **Hotkey:** Carbon `RegisterEventHotKey` — funciona sistema-wide sem Accessibility
- **Áudio:** AVAudioEngine com mono 16kHz — óptimo para Whisper
- **Whisper prompt:** Vocabulário pessoal passado como `prompt` → melhora reconhecimento de nomes
- **Keychain:** API key nunca em UserDefaults — sempre em Keychain
- **Free trial:** Rastreado em UserDefaults (minutos) — não requer servidor
