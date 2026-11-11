// Internal: sliding-window burst detection. Not exported.

/// A run of events `[first, last]` (indices into the input list) in which
/// every event belongs to at least one window of length `window` holding at
/// least `minCount` events. Overlapping qualifying windows are merged.
class WindowCluster {
  const WindowCluster(this.first, this.last);
  final int first;
  final int last;
  int get count => last - first + 1;
}

/// Finds bursts in sorted [timesUs] (microseconds). A window is inclusive:
/// events exactly [windowUs] apart are in the same window. O(n).
List<WindowCluster> findBursts(List<int> timesUs, int windowUs, int minCount) {
  final out = <WindowCluster>[];
  if (timesUs.isEmpty) return out;
  final need = minCount < 1 ? 1 : minCount;
  var i = 0;
  var curFirst = -1, curLast = -1;
  for (var j = 0; j < timesUs.length; j++) {
    while (timesUs[j] - timesUs[i] > windowUs) {
      i++;
    }
    if (j - i + 1 >= need) {
      if (curFirst >= 0 && i <= curLast) {
        curLast = j;
      } else {
        if (curFirst >= 0) out.add(WindowCluster(curFirst, curLast));
        curFirst = i;
        curLast = j;
      }
    }
  }
  if (curFirst >= 0) out.add(WindowCluster(curFirst, curLast));
  return out;
}
