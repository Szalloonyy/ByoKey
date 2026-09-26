<?php
/**
 * LKW – 3D-Ladeplaner (Beta 9.7)
 * Seite mit Menü; der Planer selbst läuft als eigene App in lkw-app.php
 * (eingebettet im iframe, damit sich sein Vollbild-Layout und das
 * DispoHub-Layout nicht in die Quere kommen).
 * Erstellt mit ❤️ durch MS
 */
require_once __DIR__ . '/includes/functions.php';

if (!is_installed()) { header('Location: install.php'); exit; }
$user = require_login();
ensure_schema();

if (!may_use_module('lkw')) { header('Location: index.php'); exit; }
?>
<?php layout_header('LKW', 'lkw'); ?>

<div class="lkw-page">
  <iframe class="lkw-frame" id="lkwFrame" src="lkw-app.php" title="LKW-Ladeplaner (3D)"
          allow="fullscreen; clipboard-write" allowfullscreen></iframe>
</div>

<?php
// Tastenkürzel des Planers (1/2/3, X, V, T …) wirken sofort, ohne erst ins Bild zu klicken.
$inlineJs = '<script>(function(){var f=document.getElementById("lkwFrame");'
  . 'f.addEventListener("load",function(){try{f.contentWindow.focus();}catch(e){}});})();</script>';
layout_footer($inlineJs);
?>
