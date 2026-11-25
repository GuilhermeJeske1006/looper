# Jeske Looper

App nativo para macOS (Apple Silicon) que grava o áudio real do Yamaha CK61 pela USB, salva loops e repete o escolhido sem pausas enquanto você continua tocando.

Feito com Swift, SwiftUI, AVAudioEngine e Core Audio. Não usa dependências externas.

## Compilar e instalar

Basta ter as Command Line Tools da Apple (`xcode-select --install`); o Xcode não é necessário.

```bash
scripts/build.sh      # compila (release, arm64), gera o ícone e monta dist/Jeske Looper.app com assinatura ad hoc
scripts/install.sh    # copia para /Applications; uma versão já instalada vai antes para dist/backups/
scripts/make_dmg.sh   # opcional: dist/Jeske Looper.dmg com atalho para Applications
```

Para assinar com um certificado próprio: `SIGN_IDENTITY="Developer ID Application: …" scripts/build.sh`.

## Teclado do Mac

| Tecla | Ação |
|---|---|
| Espaço | Gravar / Parar gravação |
| 1 a 9 | Repetir o loop 1 a 9 (fileira de números ou teclado numérico) |
| ↩ | Repetir o loop selecionado |
| Esc | Parar a repetição |
| ↑ ↓ | Selecionar loop |
| ← → | Volume (passos de 5%) |
| ⇧ + número ou ↩ | Trocar de loop na hora |

As teclas podem ser trocadas em Ajustes (⌘,) › Teclado. A opção "Funcionar também com outro app na frente" ativa ⌃⌥ + a mesma tecla em qualquer app, usando `RegisterEventHotKey`, que não exige permissão de Acessibilidade.

## Troca de loop sem pausa

Com um loop tocando, escolher outro faz ele entrar no fim exato da volta atual, com transição de 10 ms. Ele aparece como "Próximo" na lista. Escolher o mesmo loop de novo troca na hora; escolher o loop atual cancela a fila. Em Ajustes › Loops dá para preferir a troca imediata, com crossfade.

Ao salvar, o silêncio antes da primeira nota e depois da última é cortado (limiar de −60 dBFS, com margens de 10 ms e 30 ms). Para loops já gravados, use "Cortar silêncio das bordas" no menu ⋯; o arquivo anterior vai para o Lixo.

## Validar

```bash
swift run -c release LooperChecks             # usa os dispositivos reais (reprodução em volume 0)
swift run -c release LooperChecks --offline   # só o que não precisa de áudio
JESKE_SNAPSHOT_DIR=/tmp/jl .build/arm64-apple-macosx/release/JeskeLooper
                                              # desenha as janelas em PNG e testa as teclas com eventos reais
```

## Estrutura

- `Sources/LooperCore`: dispositivos (Core Audio), gravação (`InputEngine`), reprodução (`LoopPlayer`), arquivos (`LoopStore`) e regras do app (`LooperController`).
- `Sources/JeskeLooper`: a janela em SwiftUI.
- `Sources/LooperChecks`: verificações automáticas.
- `Resources`: `Info.plist` (inclui `NSMicrophoneUsageDescription`) e entitlements.

## Detalhes de funcionamento

- Entrada e saída usam engines separadas, então podem ser aparelhos diferentes, com taxas de amostragem diferentes.
- A entrada nunca é enviada para a saída.
- As gravações são salvas em WAV PCM 24 bits, com a taxa de amostragem da entrada e os canais 1–2. O recorte começa e termina no instante exato dos cliques.
- A reprodução é gerada em blocos de 50 ms, cerca de 200 ms à frente do que se ouve, num único player. Por isso as voltas e as trocas de loop emendam sem nenhuma amostra de silêncio.
- Loops de até 45 s ficam na memória. Os mais longos são lidos do disco aos poucos.
- Um loop com outra taxa de amostragem é convertido para a da saída. Nos longos, a conversão é feita uma vez e fica em cache, em `~/Library/Caches`.
- Uma rampa de cerca de 3 ms é aplicada na emenda só quando o fim e o início não se encaixam. Ela não altera a duração e o arquivo original não é modificado.
- Os loops ficam em `~/Music/Jeske Looper/Loops`, com o índice em `loops.json`.
