{{flutter_js}}
{{flutter_build_config}}

// Keep every request on the site that hosts the app (privacy, a strict
// Content Security Policy and isolated networks):
// - CanvasKit is loaded from this site's canvaskit/ folder, never from
//   www.gstatic.com (build with --no-web-resources-cdn as well).
// - Roboto is bundled (pubspec.yaml), so it is not downloaded from
//   fonts.gstatic.com.
// - Fallback fonts for characters Roboto lacks (for example CJK or emoji in
//   room names) are looked for in fonts/fallback/ on this site instead of
//   fonts.gstatic.com. That folder is empty by default, so such characters
//   show as boxes; see the README section "Hosting the web build".
_flutter.loader.load({
  config: {
    canvasKitBaseUrl: 'canvaskit/',
    fontFallbackBaseUrl: 'fonts/fallback/',
  },
});
