package engine

import "sort"

func sortedCounters(m map[string]*TrafficCounter) []TrafficCounter {
	out := make([]TrafficCounter, 0, len(m))
	for _, c := range m {
		out = append(out, *c)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Tag < out[j].Tag })
	return out
}
