/// Reusable, accessible building blocks for every screen.
///
/// Import this one file from screens:
/// `import 'package:metrics_visualizer/ui/widgets/widgets.dart';`
///
/// Guidelines for screen authors:
/// * wrap the screen in [AnalysisPage] (handles no-data/loading/error states
///   and adds the page heading); the shell already shows the [FilterBar];
/// * put charts in [AccessibleChartCard] with a plain-language `summary` and
///   a [ChartTable] holding the same numbers;
/// * colour series with `ChartPalette.of(context).colorAt(i)` / `patternAt(i)`
///   and add a [PatternLegend]; group beyond 8 series into "Other";
/// * take every animation duration from `Motion.of(context)`;
/// * format numbers and times with `Fmt.of(context)`;
/// * mark headings with [Heading] or [SectionHeader] (heading semantics with
///   a level: page 1, section 2, card 3, inside a card 4);
/// * lay cards out with [ResponsiveGrid] so they reflow on narrow windows.
library;

export '../theme/chart_palette.dart';
export '../theme/chart_patterns.dart';
export '../theme/motion.dart';
export 'accessible_chart_card.dart';
export 'analysis_page.dart';
export 'filter_bar.dart';
export 'focus_ring.dart';
export 'app_dropdown_menu.dart';
export 'form_fields.dart';
export 'formatters.dart';
export 'guide_link.dart';
export 'keyboard_shortcuts.dart';
export 'kpi_tile.dart';
export 'multi_select_dialog.dart';
export 'pattern_legend.dart';
export 'responsive_grid.dart';
export 'section_header.dart';
export 'status_widgets.dart';
