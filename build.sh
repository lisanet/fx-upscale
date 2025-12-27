#!/bin/bash

# Beendet das Skript sofort, wenn ein Befehl fehlschlägt
set -e

# Pfade zu den Dateien
METAL_FILE="Sources/Upscaling/Shaders/Sharpen.metal"
SWIFT_FILE="Sources/Upscaling/Shaders/SharpenShader.swift"

echo "Generiere $SWIFT_FILE aus $METAL_FILE..."

# Liest den Inhalt der Metal-Datei und stellt ihn dem Swift-Code voran.
# Verwendet ein Here-Document (<<EOF) für die Vorlage.
cat > "$SWIFT_FILE" <<EOF
import Foundation

// Diese Datei wird automatisch durch das build.sh-Skript generiert.
// Ändern Sie diese Datei nicht direkt, sondern bearbeiten Sie stattdessen Sharpen.metal.

enum Shaders {
    static let sharpenLuma = """
$(cat "$METAL_FILE")
"""
}
EOF

echo "$SWIFT_FILE wurde erfolgreich generiert."

# Führt den Swift-Build-Befehl aus und leitet alle an dieses Skript
# übergebenen Argumente (wie -c release) weiter.
echo "Starte Swift Build..."
swift build "$@"

echo "Build abgeschlossen."
