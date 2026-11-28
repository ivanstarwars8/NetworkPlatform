package engine

import (
	"sort"

	"github.com/metacubex/mihomo/tunnel/statistic"
)

// MaxConnections bounds one Connections reply (a limit of this project: the reply crosses the C ABI and
// then the app/extension message channel, whose replies are capped at 64 KiB).
const MaxConnections = 200

// Connection is one connection the core tracks. Destination is the host the connection was opened for
// (the sniffed or requested name, else the IP) with its port: the user's data, for display in the app only.
type Connection struct {
	ID          string   `json:"id"`
	Network     string   `json:"network"`
	Destination string   `json:"destination"`
	Rule        string   `json:"rule,omitempty"`
	Chain       []string `json:"chain,omitempty"`
	Upload      int64    `json:"upload"`
	Download    int64    `json:"download"`
	StartMs     int64    `json:"startMs"` // Unix milliseconds
}

// Connections is a bounded snapshot: Total counts every tracked connection, Items holds the newest ones.
type Connections struct {
	Total int          `json:"total"`
	Items []Connection `json:"items"`
}

// Connections returns up to limit (1...MaxConnections; other values mean MaxConnections) of the newest
// connections the core's tracker holds. It reads the tracker in-process; nothing is probed.
func (e *Engine) Connections(limit int) (out Connections, rerr *Error) {
	defer guard(&rerr)
	if e.current() == nil {
		return out, newError(CodeNotRunning, "engine is not running")
	}
	if limit <= 0 || limit > MaxConnections {
		limit = MaxConnections
	}
	out.Items = []Connection{}
	statistic.DefaultManager.Range(func(c statistic.Tracker) bool {
		out.Total++
		info := c.Info()
		if info == nil || info.Metadata == nil {
			return true
		}
		item := Connection{
			ID:          info.UUID.String(),
			Network:     info.Metadata.NetWork.String(),
			Destination: info.Metadata.RemoteAddress(),
			Upload:      info.UploadTotal.Load(),
			Download:    info.DownloadTotal.Load(),
			StartMs:     info.Start.UnixMilli(),
		}
		if info.Rule != "" {
			item.Rule = info.Rule
			if info.RulePayload != "" {
				item.Rule += "(" + info.RulePayload + ")"
			}
		}
		// The core lists the chain from the last hop to the first; the app shows it in travel order.
		for i := len(info.Chain) - 1; i >= 0; i-- {
			item.Chain = append(item.Chain, info.Chain[i])
		}
		out.Items = append(out.Items, item)
		return true
	})
	sort.Slice(out.Items, func(i, j int) bool {
		if out.Items[i].StartMs != out.Items[j].StartMs {
			return out.Items[i].StartMs > out.Items[j].StartMs
		}
		return out.Items[i].ID < out.Items[j].ID
	})
	if len(out.Items) > limit {
		out.Items = out.Items[:limit]
	}
	return out, nil
}
