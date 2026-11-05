#!/usr/bin/env python3
"""Sincroniza Shared/Localizable.xcstrings con los textos que el compilador extrae del código.

xcodebuild no actualiza el catálogo (Xcode sí, al compilar en el IDE). Uso:
  xcodebuild -project Cue.xcodeproj -scheme CueMac -derivedDataPath build/loc SWIFT_EMIT_LOC_STRINGS=YES build
  xcodebuild -project Cue.xcodeproj -scheme Cue -destination 'generic/platform=iOS Simulator' \
      -derivedDataPath build/loc SWIFT_EMIT_LOC_STRINGS=YES build
  python3 tools/sync-strings.py build/loc
Agrega las claves nuevas (sin traducir), quita las que ya no están y lista las que faltan en español.
El inglés es el idioma base: la clave es el texto en inglés.
"""
import glob, json, os, re, sys

root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
build = sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, 'build/loc')
catalog_path = os.path.join(root, 'Shared/Localizable.xcstrings')

found = {}
for f in glob.glob(os.path.join(build, 'Build/Intermediates.noindex/Cue.build/**/*.stringsdata'), recursive=True):
    data = json.load(open(f))
    src = os.path.relpath(data['source'], root)
    for items in data['tables'].values():
        for item in items:
            found.setdefault(item['key'], f"{src}:{item['location']['startingLine']}")
if not found:
    sys.exit(f"No hay .stringsdata en {build}: compila con SWIFT_EMIT_LOC_STRINGS=YES.")

catalog = json.load(open(catalog_path))
old = catalog['strings']
# Sin letras (números, atajos ⌃⌥…) o marcas: no se traducen.
untranslatable = re.compile(r'^[^A-Za-z]*$|^(Cue|Pronter|Whisper|Prompter)$|^[⌃⌥⌘].*')
strings, missing = {}, []
for key in sorted(found):
    if key in old:
        strings[key] = old[key]
    elif untranslatable.match(key):
        strings[key] = {"shouldTranslate": False}
    else:
        strings[key] = {}
    entry = strings[key]
    if entry.get("shouldTranslate") is not False and "es" not in entry.get("localizations", {}):
        missing.append(key)
removed = sorted(set(old) - set(found))
catalog['strings'] = strings
json.dump(catalog, open(catalog_path, 'w'), ensure_ascii=False, indent=2, sort_keys=True)
print(f"{len(found)} claves · {len(removed)} quitadas · {len(missing)} sin español")
for key in missing:
    print(f"  falta es: {key!r}  ({found[key]})")
