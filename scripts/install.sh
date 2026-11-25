#!/bin/bash
# Instala dist/Jeske Looper.app em /Applications.
# Uma instalação existente é copiada antes para dist/backups/, e a troca é feita por
# renomeação: se algo falhar, a versão instalada continua intacta.
# Sem permissão de escrita em /Applications, gera dist/Jeske Looper.dmg.
# Com --manter-aberto, não fecha o app em uso: a versão nova vale na próxima vez que ele for aberto.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Jeske Looper"
SOURCE="dist/$APP_NAME.app"
TARGET="/Applications/$APP_NAME.app"
STAGED="/Applications/.$APP_NAME.app.novo"
OLD="/Applications/.$APP_NAME.app.antigo"

[ -d "$SOURCE" ] || { echo "Rode scripts/build.sh antes."; exit 1; }

if [ ! -w /Applications ]; then
    echo "Sem permissão para escrever em /Applications; gerando .dmg…"
    scripts/make_dmg.sh
    exit 0
fi

KEEP_RUNNING=0
[ "${1:-}" = "--manter-aberto" ] && KEEP_RUNNING=1

if [ "$KEEP_RUNNING" = 0 ] && pgrep -x JeskeLooper >/dev/null; then
    echo "→ Fechando o Jeske Looper aberto (uma gravação em andamento é salva)…"
    osascript -e 'tell application id "com.guilhermejeske.JeskeLooper" to quit' || true
    for _ in $(seq 1 50); do pgrep -x JeskeLooper >/dev/null || break; sleep 0.2; done
    if pgrep -x JeskeLooper >/dev/null; then echo "Feche o Jeske Looper e rode de novo."; exit 1; fi
fi

rm -rf "$STAGED" "$OLD"
ditto "$SOURCE" "$STAGED"
codesign --verify --strict "$STAGED"

if [ -e "$TARGET" ]; then
    mkdir -p dist/backups
    BACKUP="dist/backups/$APP_NAME $(date +%Y%m%d-%H%M%S).app"
    echo "→ Guardando a versão instalada em $BACKUP"
    ditto "$TARGET" "$BACKUP"
    if ! mv "$TARGET" "$OLD"; then
        rm -rf "$STAGED"
        echo "Não foi possível substituir $TARGET; a versão instalada não foi alterada."
        exit 1
    fi
fi

mv "$STAGED" "$TARGET"
rm -rf "$OLD"
codesign --verify --strict "$TARGET"
echo "✓ Instalado em $TARGET"
if [ "$KEEP_RUNNING" = 1 ] && pgrep -x JeskeLooper >/dev/null; then
    echo "  O app aberto continua com a versão anterior; feche e abra de novo para usar a nova."
fi
