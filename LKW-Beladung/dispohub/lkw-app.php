<?php
/**
 * LKW – 3D-Ladeplaner als eigenständige App (Beta 9.7)
 * Wird von lkw.php im iframe geladen. Liefert die Vorlage
 * includes/lkw-planer.html aus und setzt die Adressen von three.js und den
 * Schriften (assets/lkw/, mit ?v= gegen alte Stände im Browser-Cache) ein.
 * Der Planer lädt nichts von fremden Servern und speichert nur im Browser.
 * Erstellt mit ❤️ durch MS
 */
require_once __DIR__ . '/includes/functions.php';

if (!is_installed()) { http_response_code(503); exit; }

// Im iframe nicht zur Anmeldeseite umleiten (die erschiene sonst IM Rahmen),
// sondern das ganze Fenster wechseln.
$user = current_user();
if (!$user) {
    exit('<!doctype html><meta charset="utf-8"><script>top.location.href = "login.php";</script>');
}
ensure_schema();
if (!may_use_module('lkw')) {
    exit('<!doctype html><meta charset="utf-8"><script>top.location.href = "index.php";</script>');
}
// Direkt aufgerufen (nicht im Rahmen)? Dann zur Seite mit Menü.
if (strtolower((string) ($_SERVER['HTTP_SEC_FETCH_DEST'] ?? '')) === 'document') {
    header('Location: lkw.php');
    exit;
}
session_release();

$html = @file_get_contents(__DIR__ . '/includes/lkw-planer.html');
if ($html === false) {
    http_response_code(500);
    exit('Die Vorlage includes/lkw-planer.html fehlt.');
}

header('Content-Type: text/html; charset=utf-8');
echo strtr($html, [
    '{{FONTS_CSS}}' => e(asset_url('assets/lkw/fonts/fonts.css')),
    '{{THREE_JS}}'  => e(asset_url('assets/lkw/three.min.js')),
    '{{ORBIT_JS}}'  => e(asset_url('assets/lkw/OrbitControls.js')),
    // Ladeplan je Benutzer getrennt speichern (mehrere Disponenten an einem PC)
    '{{STORE_PREFIX}}' => 'lkw_u' . (int) $user['id'] . '_',
]);
