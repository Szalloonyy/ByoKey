#!/usr/bin/env python3
"""
Baut den LKW-Ladeplaner als eingebautes Modul „LKW“ in DispoHub ein.

    python3 einbau.py /pfad/zu/dispohub [--version 9.7]

Was passiert:
  1. includes/lkw-planer.html   Vorlage, erzeugt aus ../index.html
                                 (ohne Offline-Cache und App-Symbol; three.js und
                                 Schriften kommen aus assets/lkw/)
  2. assets/lkw/                three.js, OrbitControls, Schriften, Lizenzen
  3. lkw.php, lkw-app.php       Seite mit Menü und die App im Rahmen
  4. Anmeldung des Moduls in DispoHub:
       includes/functions.php   modules_registry(): Eintrag 'lkw'
       includes/layout.php      menu_base_items(), menu_icon_default(),
                                neue Menüpunkte hinter ihren Vorgänger statt ans Ende
       admin.php                Admin → Menü nutzt dieselbe Reihenfolge
       404.php                  Startseiten-Liste
       assets/live.js           Seitenname „LKW“ in der Anwesenheit
       assets/style.css         Rahmen füllt das Fenster
  5. mit --version: APP_VERSION / APP_VERSION_LABEL setzen (z. B. 9.7)

Jeder Schritt ist wiederholbar: Was schon drin ist, bleibt unverändert. Findet
das Skript eine Stelle nicht (DispoHub stark umgebaut), bricht es mit einer
Meldung ab, ohne halbe Änderungen an dieser Datei zu schreiben.
"""
import os
import re
import shutil
import sys

HIER = os.path.dirname(os.path.abspath(__file__))
PLANER = os.path.dirname(HIER)


class Fehlt(Exception):
    pass


def lesen(pfad):
    with open(pfad, encoding='utf-8', newline='') as f:
        return f.read()


def schreiben(pfad, text):
    os.makedirs(os.path.dirname(pfad), exist_ok=True)
    with open(pfad, 'w', encoding='utf-8', newline='') as f:
        f.write(text)


def ersetzen(text, muster, ersatz, was, flags=re.S):
    neu, n = re.subn(muster, ersatz, text, count=1, flags=flags)
    if n != 1:
        raise Fehlt(was)
    return neu


# ---------------------------------------------------------------------------
# 1. Vorlage aus der Website-Fassung
# ---------------------------------------------------------------------------
def vorlage():
    t = lesen(os.path.join(PLANER, 'index.html'))
    t = ersetzen(t, r'<!-- web:start -->.*?<!-- web:end -->',
                 '<link rel="stylesheet" href="{{FONTS_CSS}}">', 'index.html: <!-- web:start -->')
    t = ersetzen(t, r'<!-- web:scripts:start -->.*?<!-- web:scripts:end -->',
                 '<script src="{{THREE_JS}}"></script>\n<script src="{{ORBIT_JS}}"></script>',
                 'index.html: <!-- web:scripts:start -->')
    t = ersetzen(t, r'// Offline-Cache[^\n]*\n/\* web:sw \*/[^\n]*\n', '', 'index.html: /* web:sw */')
    t = ersetzen(t, r"const STORE_KEY = '([^']+)';", r"const STORE_KEY = '{{STORE_PREFIX}}\1';",
                 'index.html: STORE_KEY')
    kopf = ('<!-- Vorlage für lkw-app.php (DispoHub-Modul „LKW“). Nicht von Hand ändern:\n'
            '     erzeugt von LKW-Beladung/dispohub/einbau.py aus LKW-Beladung/index.html. -->\n')
    t = t.replace('<!doctype html>\n', '<!doctype html>\n' + kopf, 1)
    for p in ('{{FONTS_CSS}}', '{{THREE_JS}}', '{{ORBIT_JS}}', '{{STORE_PREFIX}}'):
        assert t.count(p) == 1, p
    assert 'serviceWorker' not in t and 'manifest' not in t and 'vendor/' not in t
    return t


# ---------------------------------------------------------------------------
# 4. Anmeldung im DispoHub-Kern
# ---------------------------------------------------------------------------
REGISTRY = """        'lkw' => [
            'label'       => 'LKW',
            'description' => '3D-Ladeplaner für Hängerzug, Kammer-Auto, Maschine und Anhänger: Rollbehälter, Paletten, TK-Isotainer und Fleisch auf die Stellplätze verteilen.',
            'icon'        => '🚛',
            'default'     => true,
            'locked'      => false,
        ],
"""

MENU = """    if (may_use_module('lkw')) {
        $items['lkw'] = ['label' => 'LKW', 'icon' => '🚛', 'href' => 'lkw.php'];
    }
"""

ORDER_FN = """/**
 * Reihenfolge der Menüpunkte: die gespeicherte zuerst. Punkte, die dort noch
 * fehlen (z. B. ein neues Modul nach einem Update), kommen hinter ihren
 * Vorgänger aus der Standardreihenfolge und nicht mehr ans Ende unter
 * „Administration" (Beta 9.7).
 */
function menu_ordered(array $base, array $order): array
{
    $ordered = [];
    foreach ($order as $k) {
        if ((is_string($k) || is_int($k)) && isset($base[$k])) { $ordered[$k] = $base[$k]; }
    }
    $vorher = null;
    foreach ($base as $k => $v) {
        if (!isset($ordered[$k])) {
            $neu = $vorher === null ? [$k => $v] : [];
            foreach ($ordered as $kk => $vv) {
                $neu[$kk] = $vv;
                if ($kk === $vorher) { $neu[$k] = $v; }
            }
            $ordered = $neu;
        }
        $vorher = $k;
    }
    return $ordered;
}

"""

CSS = """
/* ============================================================
   BETA 9.7 · LKW – 3D-Ladeplaner: der Rahmen füllt das Fenster
   ============================================================ */
body[class] .app-shell:has(.lkw-page){min-height:0}
body[class] .main-wrap:has(.lkw-page){height:100vh;height:100dvh;min-height:0}
body[class] main.content:has(.lkw-page){display:flex;flex-direction:column;min-height:0;max-width:none;padding:12px}
.lkw-page{position:relative;flex:1 1 auto;min-height:320px}
.lkw-frame{position:absolute;inset:0;width:100%;height:100%;display:block;border:0;
  border-radius:var(--r-md,12px);background:#0d1117;box-shadow:var(--sh-2,0 2px 10px rgba(0,0,0,.12))}
@media(max-width:600px){
  body[class] main.content:has(.lkw-page){padding:0}
  .lkw-frame{border-radius:0;box-shadow:none}
}
"""


def kern(root, version):
    """Rechnet alle Änderungen aus; geschrieben wird erst, wenn jede Stelle gefunden wurde."""
    geaendert = {}

    def datei(rel, fn):
        alt = lesen(os.path.join(root, rel))
        neu = fn(alt)
        if neu != alt:
            geaendert[rel] = neu

    # functions.php: Modul-Registry (+ Version)
    def functions(t):
        m = re.search(r'function modules_registry\(\): array\s*\{\s*return \[(.*?)\n    \];\n\}', t, re.S)
        if not m:
            raise Fehlt('includes/functions.php: modules_registry()')
        if "'lkw' =>" not in m.group(1):
            t = t[:m.end(1)] + '\n' + REGISTRY.rstrip('\n') + t[m.end(1):]
        if version:
            t = ersetzen(t, r"define\('APP_VERSION', '[^']*'\);", f"define('APP_VERSION', 'beta-{version}');",
                         'includes/functions.php: APP_VERSION')
            t = ersetzen(t, r"define\('APP_VERSION_LABEL', '[^']*'\);", f"define('APP_VERSION_LABEL', 'Beta {version}');",
                         'includes/functions.php: APP_VERSION_LABEL')
        return t
    datei('includes/functions.php', functions)

    # layout.php: Menüpunkt, Piktogramm, Reihenfolge
    def layout(t):
        if "$items['lkw']" not in t:
            t = ersetzen(t, r"(    if \(may_use_module\('tour'\)\) \{\n.*?\n    \}\n)", lambda m: m.group(1) + MENU,
                         "includes/layout.php: menu_base_items() → Block 'tour'")
        m = re.search(r'static \$eingebaut = \[(.*?)\];', t, re.S)
        if not m:
            raise Fehlt('includes/layout.php: menu_icon_default() → $eingebaut')
        if "'lkw'" not in m.group(1):
            innen = m.group(1).replace("'admin'", "'lkw', 'admin'", 1)
            if innen == m.group(1):
                raise Fehlt("includes/layout.php: $eingebaut ohne 'admin'")
            t = t[:m.start(1)] + innen + t[m.end(1):]
        if 'function menu_ordered(' not in t:
            t = ersetzen(t, r'(/\*\* Fertiges Menü \(sortiert)', lambda m: ORDER_FN + m.group(1),
                         'includes/layout.php: app_menu()')
        t = ersetzen_optional(t,
            r"    // Reihenfolge: konfigurierte zuerst, danach restliche in Standardreihenfolge\n"
            r"    \$ordered = \[\];\n"
            r"    foreach \(\$cfg\['order'\] as \$k\) \{\n        if \(isset\(\$base\[\$k\]\)\) \{ \$ordered\[\$k\] = \$base\[\$k\]; \}\n    \}\n"
            r"    foreach \(\$base as \$k => \$v\) \{\n        if \(!isset\(\$ordered\[\$k\]\)\) \{ \$ordered\[\$k\] = \$v; \}\n    \}\n",
            "    // Reihenfolge: konfigurierte zuerst, fehlende hinter ihren Vorgänger\n"
            "    $ordered = menu_ordered($base, $cfg['order']);\n",
            'menu_ordered($base, $cfg[\'order\'])', 'includes/layout.php: app_menu() → Reihenfolge')
        return t
    datei('includes/layout.php', layout)

    # admin.php: Admin → Menü zeigt dieselbe Reihenfolge wie die Seitenleiste
    def admin(t):
        return ersetzen_optional(t,
            r"      \$ordered = \[\];\n"
            r"      foreach \(\$cfg\['order'\] as \$k\) \{ if \(isset\(\$base\[\$k\]\)\) \{ \$ordered\[\$k\] = \$base\[\$k\]; \} \}\n"
            r"      foreach \(\$base as \$k => \$v\) \{ if \(!isset\(\$ordered\[\$k\]\)\) \{ \$ordered\[\$k\] = \$v; \} \}\n",
            "      $ordered = menu_ordered($base, $cfg['order']);\n",
            'menu_ordered($base, $cfg[\'order\'])', 'admin.php: Admin → Menü → Reihenfolge')
    datei('admin.php', admin)

    # 404.php: Startseiten-Liste
    def seite404(t):
        m = re.search(r'\$startDateien = \[(.*?)\];', t, re.S)
        if not m:
            raise Fehlt('404.php: $startDateien')
        if "'lkw'" in m.group(1):
            return t
        innen = m.group(1).rstrip() + "\n    'lkw'       => 'lkw.php',\n"
        return t[:m.start(1)] + innen + t[m.end(1):]
    datei('404.php', seite404)

    # live.js: Seitenname in der Anwesenheit
    def live(t):
        m = re.search(r'var SEITEN = \{(.*?)\};', t, re.S)
        if not m:
            raise Fehlt('assets/live.js: var SEITEN')
        if "'lkw.php'" in m.group(1):
            return t
        innen = re.sub(r"(\n\s*)('admin\.php')", r"\1'lkw.php': 'LKW',\1\2", m.group(1), count=1)
        if innen == m.group(1):
            raise Fehlt("assets/live.js: SEITEN ohne 'admin.php'")
        return t[:m.start(1)] + innen + t[m.end(1):]
    datei('assets/live.js', live)

    # style.css: Rahmen
    def style(t):
        return t if '.lkw-page' in t else t.rstrip('\n') + '\n' + CSS
    datei('assets/style.css', style)
    return geaendert


def ersetzen_optional(t, muster, ersatz, schon_da, was):
    if schon_da in t:
        return t
    neu, n = re.subn(muster, lambda m: ersatz, t, count=1)
    if n != 1:
        raise Fehlt(was)
    return neu


# ---------------------------------------------------------------------------
def main():
    args = sys.argv[1:]
    version = None
    if '--version' in args:
        i = args.index('--version')
        version = args[i + 1]
        del args[i:i + 2]
        if not re.fullmatch(r'\d+(\.\d+)*', version):
            sys.exit('--version erwartet eine Zahl wie 9.7')
    if len(args) != 1:
        sys.exit(__doc__)
    root = os.path.abspath(args[0])
    if not os.path.isfile(os.path.join(root, 'includes', 'functions.php')):
        sys.exit(f'{root} ist kein DispoHub-Ordner (includes/functions.php fehlt).')

    try:
        html = vorlage()
        geaendert = kern(root, version)
    except Fehlt as f:
        sys.exit(f'Stelle nicht gefunden: {f}. Nichts geändert. Bitte von Hand einbauen (siehe README.md).')

    for rel, text in geaendert.items():
        schreiben(os.path.join(root, rel), text)
    schreiben(os.path.join(root, 'includes', 'lkw-planer.html'), html)
    ziel = os.path.join(root, 'assets', 'lkw')
    os.makedirs(os.path.join(ziel, 'fonts'), exist_ok=True)
    for name in ('three.min.js', 'OrbitControls.js', 'LICENSE-three.txt'):
        shutil.copyfile(os.path.join(PLANER, 'vendor', name), os.path.join(ziel, name))
    for name in sorted(os.listdir(os.path.join(PLANER, 'fonts'))):
        shutil.copyfile(os.path.join(PLANER, 'fonts', name), os.path.join(ziel, 'fonts', name))
    for name in ('lkw.php', 'lkw-app.php'):
        shutil.copyfile(os.path.join(HIER, name), os.path.join(root, name))

    print('Fertig. Neu oder aktualisiert: lkw.php, lkw-app.php, includes/lkw-planer.html, assets/lkw/')
    print('Angepasst: ' + (', '.join(geaendert) if geaendert else 'nichts, war schon eingebaut'))


if __name__ == '__main__':
    main()
